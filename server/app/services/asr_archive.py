"""Write transcript + durable ledger before applying the explicit cleanup gates."""
from __future__ import annotations

import json
import os
import re
from datetime import datetime
from pathlib import Path

from app.services.asr_engine import sha256
from app.services.asr_settings import AsrSettings
from app.services.atomic_files import atomic_json


def covered_transcript(source: Path, mtime: float, output: Path) -> Path | None:
    """Legacy rule: exact recording stem + newer mtime + no INCOMPLETE header."""
    matches = []
    for path in output.glob("*.txt"):
        if path.stat().st_mtime <= mtime:
            continue
        name = re.sub(r"^\d{4}-\d{2}-\d{2}_", "", path.stem)
        exact = name == source.stem + "_AI转写"
        with path.open("r", encoding="utf-8", errors="replace") as f:
            header = f.read(2000).split("=" * 50)[0]
        own = "任务ID:" in header and f"来源: {source.name} |" in header
        if (exact or own) and "INCOMPLETE" not in header:
            matches.append(path)
    return max(matches, key=lambda p: p.stat().st_mtime) if matches else None


def ledger(output: Path, marker: str, text: str) -> None:
    path = output / "00-转写完成清单.md"
    # One application worker owns this append. No whole-file rewrite of user ledger.
    if path.exists() and marker in path.read_text("utf-8"):
        return
    header = not path.exists() or path.stat().st_size == 0
    with path.open("a", encoding="utf-8") as f:
        if header:
            f.write("# 课堂录音转写完成清单\n\n## 五、处理日志\n\n| 处理时间 | 任务与结果 |\n| --- | --- |\n")
        clean = text.replace("|", "／").replace("\n", " ")
        f.write(f"| {datetime.now():%Y-%m-%d %H:%M:%S} | {clean} <!-- {marker} --> |\n")
        f.flush()
        os.fsync(f.fileno())


def publish(source: Path, work: Path, job_id: str, source_hash: str,
            source_mtime: float, course: str, result: dict, cfg: AsrSettings) -> dict:
    output = Path(cfg.output_dir)
    receipt = work / f"archive-{job_id}.json"
    if receipt.exists():
        saved = json.loads(receipt.read_text("utf-8"))
        if not Path(saved["output_path"]).is_file() or sha256(Path(saved["output_path"])) != saved["output_sha256"]:
            raise ValueError("已归档转写文件被移动或修改，保留音频，请检查输出目录")
        output = Path(saved["output_path"]).parent
        if saved["source_note"] == "待清理" and (not cfg.delete_source or saved["chars"] < cfg.min_chars):
            saved["source_note"] = "保留：当前删除设置或字数门槛不允许清理"
    else:
        if not source.is_file() or sha256(source) != source_hash:
            raise ValueError("音频在转写期间已被替换，保留新文件，不删除源音频")
        segments = result["segments"]
        chars = sum(len(x["t"].strip()) for x in segments)
        last = max((x["e"] for x in segments), default=0)
        complete = bool(segments) and result.get("aligned", False) and result["duration"] > 0 and last > 0 and last >= result["duration"] - 120 and result.get("coverage_complete", True)
        safe = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", source.stem).strip(" .") or "未知课程"
        date = datetime.fromtimestamp(source_mtime).strftime("%Y-%m-%d")
        base = f"{date}_{safe}_AI转写"
        target = output / f"{base}.txt"
        marker = f"任务ID: {job_id}"
        # Crash recovery: reuse only a fully-written file bearing this job ID.
        body = f"{course} - AI转写\n{marker}\n来源: {source.name} | 音频日期: {date}\n时长: {result['duration']:.2f} 秒 | 引擎: {result['engine']}\n状态: {'完整' if complete else 'INCOMPLETE（保留音频，可手动继续）'}\n\n"
        for s in segments:
            minute, second = divmod(max(0, s["s"]), 60)
            body += f"[{int(minute):02}:{second:05.2f}] {s['t']}\n"
        encoded = body.encode("utf-8")
        candidates = [target, output / f"{base}_{job_id}.txt"]
        target = candidates[-1]
        for candidate in candidates:
            if candidate.exists():
                if candidate.read_bytes() == encoded:
                    target = candidate
                    break
                continue
            try:
                with candidate.open("xb") as f:
                    f.write(encoded)
                    f.flush()
                    os.fsync(f.fileno())
                target = candidate
                break
            except FileExistsError:
                continue
        else:
            raise ValueError("同名转写存在不同内容，保留旧文件和音频，请检查后重试")
        reason = "待清理" if cfg.delete_source and complete and chars >= cfg.min_chars else (
            "保留：未开启转写后删除" if not cfg.delete_source else
            "保留：转写不完整或缺少可靠时间戳" if not complete else f"保留：{chars} 字，少于 {cfg.min_chars} 字")
        saved = {"output_path": str(target), "output_sha256": sha256(target), "duration_sec": result["duration"],
                 "segments": len(segments), "chars": chars, "elapsed_sec": result.get("elapsed_sec", 0),
                 "complete": complete, "source_deleted": False, "source_note": reason, "ledger_appended": False}
        atomic_json(receipt, saved)
    # First event confirms a persisted transcript, before deletion can occur.
    ledger(output, job_id + ":ready", f"{course} · {Path(saved['output_path']).name} · {saved['segments']} 段／{saved['chars']} 字 · {saved['source_note']}")
    saved["ledger_appended"] = True
    atomic_json(receipt, saved)
    if saved["source_note"] == "待清理":
        if source.exists():
            if sha256(source) != source_hash:
                saved["source_note"] = "保留：源音频已被替换"
            else:
                source.unlink()
                saved["source_deleted"] = True
                saved["source_note"] = "已删除：完整转写且字数达标"
        else:
            saved["source_note"] = "源音频已不存在；转写与台账已确认落盘"
            saved["source_deleted"] = True
        atomic_json(receipt, saved)
    try:
        ledger(output, job_id + ":cleanup", f"{course} · {saved['source_note']}")
    except OSError as exc:
        # The transcript and READY ledger were durably saved before deletion.
        # A final-result log failure must not falsely report retained audio.
        saved["ledger_warning"] = f"转写及前置台账已保存；最终清理结果登记失败：{exc}"
        atomic_json(receipt, saved)
    return saved
