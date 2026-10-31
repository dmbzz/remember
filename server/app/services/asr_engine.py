"""Per-file Qwen execution; resumable shards, bounded subprocesses, no folder scans."""
from __future__ import annotations

import hashlib
import asyncio
import json
import math
import os
import re
import subprocess
import threading
import time
from pathlib import Path

import httpx

from app.services.asr_settings import AsrSettings
from app.services.asr_progress import update_progress
from app.services.asr_process import ProcessTree, ProcessStopFailed, stop_owned_process


def sha256(path: Path) -> str:
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def run_process(args: list[str], log: Path, stop: threading.Event, timeout=10800) -> None:
    if stop.is_set():
        raise RuntimeError("转写已取消或中断，源录音保留")
    with log.open("ab") as output:
        proc = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        tree = ProcessTree(proc)
        if hasattr(stop, 'track_process'):
            stop.track_process(proc, tree)
        start = time.monotonic()
        try:
            while proc.poll() is None:
                if stop.wait(.5) or time.monotonic() - start > timeout:
                    raise RuntimeError("转写已中断，可在重启后从分片继续" if stop.is_set() else "转写进程超时")
            if proc.returncode:
                tail = log.read_bytes()[-4000:].decode("utf-8", errors="replace")
                raise RuntimeError(f"进程退出 {proc.returncode}：{tail}")
        finally:
            # Never release the engine lock or report cancelled while any owned
            # worker is alive. Retain handles and retry failed/timeout stop requests.
            last_error = None
            while True:
                try:
                    stop_owned_process(proc, tree)
                    break
                except ProcessStopFailed as exc:
                    message = str(exc)
                    if message != last_error:
                        output.write(('\n' + message + '\n').encode('utf-8'))
                        output.flush()
                        last_error = message
                    if hasattr(stop, 'process_stop_failed'):
                        stop.process_stop_failed(message)
                    time.sleep(1)
            tree.close()
            if hasattr(stop, 'process_exited'):
                stop.process_exited(proc)


def local_infer(source: Path, work: Path, cfg: AsrSettings, stop: threading.Event, managed_override=None) -> dict:
    # Decode all codecs through ffmpeg; Qwen receives 16-kHz mono WAV.
    wav = work / "audio.wav"
    update_progress(work, "decoding")
    if not wav.exists():
        temp = work / "audio.incoming.wav"
        run_process([cfg.ffmpeg_path, "-y", "-i", str(source), "-vn", "-ac", "1", "-ar", "16000", str(temp)], work / "decode.log", stop, 1800)
        temp.replace(wav)
    import wave
    with wave.open(str(wav), "rb") as audio:
        duration = audio.getnframes() / audio.getframerate()
    if duration <= 0:
        raise ValueError("录音为空，不能转写")
    chunks = []
    managed = managed_override or {}
    if cfg.managed_id and not managed:
        from app.services.asr_model_manager import get_model_manager
        managed = get_model_manager().receipt(cfg.managed_id)
    chunk_seconds = 30 if managed else 1200
    cache_prefix = ('m' + hashlib.sha256((cfg.managed_id+'|'+cfg.model_path+'|'+cfg.python_path).encode()).hexdigest()[:16] + '_') if managed else ''
    for i in range(math.ceil(duration / chunk_seconds)):
        offset = i * chunk_seconds
        path, output = work / f"{cache_prefix}c{i:03}.wav", work / f"{cache_prefix}c{i:03}.json"
        if output.exists():
            data = json.loads(output.read_text("utf-8"))
            end = max((x["e"] for x in data["segments"]), default=offset)
            if not data.get("aligned") or end < min(offset + chunk_seconds, duration) - min(120,chunk_seconds/2):
                output.unlink()  # only this job's generated shard
        if not path.exists():
            run_process([cfg.ffmpeg_path, "-y", "-ss", str(offset), "-i", str(wav), "-t", str(chunk_seconds), "-acodec", "pcm_s16le", str(path)], work / "decode.log", stop, 600)
        chunks.append({"audio": str(path), "output": str(output), "offset": offset})
    request = work / "request.json"
    try:
        progress = json.loads((work / "progress.json").read_text("utf-8"))
    except (OSError, ValueError):
        progress = {}
    progress_request = {"progress_path": str(work / "progress.json"), "generation": progress.get("generation"), "progress_phase": "transcribing", "managed": bool(managed), "gpu_index": managed.get('gpu_index',0)}
    request.write_text(json.dumps({"chunks": chunks, "model_path": cfg.model_path, "aligner_path": cfg.aligner_path, **progress_request}, ensure_ascii=False), "utf-8")
    worker = Path(__file__).with_name("whisper_worker.py" if cfg.mode=='local_whisper' else "qwen_worker.py")
    preferred = 'cpu' if managed.get('device')=='cpu' else 'cuda'
    python_command = [cfg.python_path] + (['-I','-X','utf8'] if managed else [])
    try:
        run_process([*python_command, str(worker), str(request), preferred], work / "qwen-gpu.log", stop)
    except RuntimeError:
        if stop.is_set() or preferred=='cpu':
            raise
        # One fallback, same Qwen model; never install or substitute another engine.
        update_progress(work, "cpu_fallback")
        run_process([*python_command, str(worker), str(request), "cpu"], work / "qwen-cpu.log", stop)
    values = [json.loads(Path(x["output"]).read_text("utf-8")) for x in chunks]
    segments = sorted([s for v in values for s in v["segments"]], key=lambda x: x["s"])
    last = max((x["e"] for x in segments), default=0)
    if last < duration - 120 and not stop.is_set():
        # Tail rescue retains the existing overlap and repetition filters.
        offset = max(0, last - 60)
        path, output = work / f"{cache_prefix}tail.wav", work / f"{cache_prefix}tail.json"
        if output.exists():
            output.unlink()
        run_process([cfg.ffmpeg_path, "-y", "-ss", str(offset), "-i", str(wav), "-acodec", "pcm_s16le", str(path)], work / "decode.log", stop, 600)
        update_progress(work, "tail")
        request.write_text(json.dumps({"chunks": [{"audio": str(path), "output": str(output), "offset": offset}], "model_path": cfg.model_path, "aligner_path": cfg.aligner_path, **progress_request, "progress_phase": "tail"}, ensure_ascii=False), "utf-8")
        try:
            run_process([*python_command, str(worker), str(request), preferred], work / "tail.log", stop)
        except RuntimeError:
            if stop.is_set() or preferred=='cpu':
                raise
            run_process([*python_command, str(worker), str(request), "cpu"], work / "tail-cpu.log", stop)
        tail = json.loads(output.read_text("utf-8"))
        from collections import Counter
        norm = lambda t: re.sub(r"[\W_]+", "", t)
        counts = Counter(norm(s["t"]) for s in tail["segments"])
        previous = ""
        for s in tail["segments"]:
            text = norm(s["t"])
            if s["s"] >= last - 1 and len(text) >= 4 and counts[text] < 3 and text != previous:
                segments.append(s)
                previous = text
        values.append(tail)
    coverage = all(v.get("aligned") and max((s["e"] for s in v["segments"]), default=0) >= min((i + 1) * chunk_seconds, duration) - min(120,chunk_seconds/2)
                   for i, v in enumerate(values[:len(chunks) - 1]))
    return {"duration": duration, "segments": segments, "aligned": all(v.get("aligned") for v in values), "coverage_complete": coverage,
            "engine": cfg.model if managed else "Qwen3-ASR-1.7B",
            "execution_device": ', '.join(sorted({str(v.get('device','未确认')) for v in values})),
            "peak_vram_mb": None if any(v.get('peak_vram_mb') is None for v in values) else max((v.get('peak_vram_mb',0) for v in values),default=0)}


async def service_infer(source: Path, cfg: AsrSettings, stop: threading.Event) -> dict:
    headers = {"Authorization": f"Bearer {cfg.api_key}"} if cfg.api_key else {}
    async def perform():
        with source.open("rb") as f:
            async with httpx.AsyncClient(timeout=httpx.Timeout(10800, connect=20), trust_env=False) as client:
                for format in ("verbose_json", "json"):
                    f.seek(0)
                    response = await client.post(cfg.base_url.rstrip("/") + "/audio/transcriptions", headers=headers,
                                files={"file": (source.name, f, "application/octet-stream")},
                                data={"model": cfg.model, "response_format": format})
                    if response.status_code == 400 and format == "verbose_json" and "response_format" in response.text:
                        continue
                    if response.status_code >= 400:
                        raise RuntimeError(f"Qwen 服务返回 HTTP {response.status_code}")
                    return response.json()
    task = asyncio.create_task(perform())
    try:
        while not task.done():
            if stop.is_set():
                raise RuntimeError("服务转写已中断；源音频保留，重启后可继续")
            await asyncio.wait({task}, timeout=.5)
        data = await task
    finally:
        if not task.done():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
    segments = [{"s": float(x["start"]), "e": float(x["end"]), "t": x["text"]} for x in data.get("segments", [])]
    aligned = bool(segments)
    if not segments and data.get("text"):
        segments = [{"s": 0, "e": 0, "t": str(data["text"])}]
    return {"duration": float(data.get("duration") or 0), "segments": segments,
            "aligned": aligned, "engine": cfg.model}


def infer(source: Path, work: Path, cfg: AsrSettings, stop: threading.Event, managed_override=None) -> dict:
    work.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    result = local_infer(source, work, cfg, stop, managed_override)
    result["elapsed_sec"] = round(time.monotonic() - start, 2)
    return result
