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


def sha256(path: Path) -> str:
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def run_process(args: list[str], log: Path, stop: threading.Event, timeout=10800) -> None:
    with log.open("ab") as output:
        proc = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        start = time.monotonic()
        try:
            while proc.poll() is None:
                if stop.wait(.5) or time.monotonic() - start > timeout:
                    raise RuntimeError("转写已中断，可在重启后从分片继续" if stop.is_set() else "转写进程超时")
            if proc.returncode:
                tail = log.read_bytes()[-4000:].decode("utf-8", errors="replace")
                raise RuntimeError(f"进程退出 {proc.returncode}：{tail}")
        finally:
            if proc.poll() is None:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True,
                                   creationflags=subprocess.CREATE_NO_WINDOW, timeout=20)
                else:
                    proc.kill()
            proc.wait(timeout=30)


def local_infer(source: Path, work: Path, cfg: AsrSettings, stop: threading.Event) -> dict:
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
    for i in range(math.ceil(duration / 1200)):
        offset = i * 1200
        path, output = work / f"c{i:03}.wav", work / f"c{i:03}.json"
        if output.exists():
            data = json.loads(output.read_text("utf-8"))
            end = max((x["e"] for x in data["segments"]), default=offset)
            if not data.get("aligned") or end < min(offset + 1200, duration) - 120:
                output.unlink()  # only this job's generated shard
        if not path.exists():
            run_process([cfg.ffmpeg_path, "-y", "-ss", str(offset), "-i", str(wav), "-t", "1200", "-acodec", "pcm_s16le", str(path)], work / "decode.log", stop, 600)
        chunks.append({"audio": str(path), "output": str(output), "offset": offset})
    request = work / "request.json"
    try:
        progress = json.loads((work / "progress.json").read_text("utf-8"))
    except (OSError, ValueError):
        progress = {}
    progress_request = {"progress_path": str(work / "progress.json"), "generation": progress.get("generation"), "progress_phase": "transcribing"}
    request.write_text(json.dumps({"chunks": chunks, "model_path": cfg.model_path, "aligner_path": cfg.aligner_path, **progress_request}, ensure_ascii=False), "utf-8")
    worker = Path(__file__).with_name("qwen_worker.py")
    try:
        run_process([cfg.python_path, str(worker), str(request), "cuda"], work / "qwen-gpu.log", stop)
    except RuntimeError:
        if stop.is_set():
            raise
        # One fallback, same Qwen model; never install or substitute another engine.
        update_progress(work, "cpu_fallback")
        run_process([cfg.python_path, str(worker), str(request), "cpu"], work / "qwen-cpu.log", stop)
    values = [json.loads(Path(x["output"]).read_text("utf-8")) for x in chunks]
    segments = sorted([s for v in values for s in v["segments"]], key=lambda x: x["s"])
    last = max((x["e"] for x in segments), default=0)
    if last < duration - 120 and not stop.is_set():
        # Tail rescue retains the existing overlap and repetition filters.
        offset = max(0, last - 60)
        path, output = work / "tail.wav", work / "tail.json"
        if output.exists():
            output.unlink()
        run_process([cfg.ffmpeg_path, "-y", "-ss", str(offset), "-i", str(wav), "-acodec", "pcm_s16le", str(path)], work / "decode.log", stop, 600)
        update_progress(work, "tail")
        request.write_text(json.dumps({"chunks": [{"audio": str(path), "output": str(output), "offset": offset}], "model_path": cfg.model_path, "aligner_path": cfg.aligner_path, **progress_request, "progress_phase": "tail"}, ensure_ascii=False), "utf-8")
        try:
            run_process([cfg.python_path, str(worker), str(request), "cuda"], work / "tail.log", stop)
        except RuntimeError:
            if stop.is_set():
                raise
            run_process([cfg.python_path, str(worker), str(request), "cpu"], work / "tail-cpu.log", stop)
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
    coverage = all(v.get("aligned") and max((s["e"] for s in v["segments"]), default=0) >= min((i + 1) * 1200, duration) - 120
                   for i, v in enumerate(values[:len(chunks) - 1]))
    return {"duration": duration, "segments": segments, "aligned": all(v.get("aligned") for v in values), "coverage_complete": coverage,
            "engine": "Qwen3-ASR-1.7B"}


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


def infer(source: Path, work: Path, cfg: AsrSettings, stop: threading.Event) -> dict:
    work.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    result = local_infer(source, work, cfg, stop)
    result["elapsed_sec"] = round(time.monotonic() - start, 2)
    return result
