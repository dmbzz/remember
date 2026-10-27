"""Readable recording names using the recording start, not upload time."""
from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path


def native_recording_start(filename: str) -> datetime | None:
    # Only interpret this app's native recorder format, never arbitrary names.
    match = re.fullmatch(r"rec_.+_\d{13}_(\d{8})_(\d{6})\.(?:m4a|wav|aac)", Path(filename).name, re.I)
    if not match:
        return None
    try:
        return datetime.strptime("".join(match.groups()), "%Y%m%d%H%M%S").astimezone()
    except ValueError:
        return None


def recording_stem(course_name: str, started_at: datetime) -> str:
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f\u200b-\u200f\ufeff]', "_", course_name).strip(" .")[:80] or "课程录音"
    start = started_at.astimezone() if started_at.tzinfo else started_at
    return f"{name}_{start:%Y-%m-%d_%H-%M-%S}"


def recording_destination(root: Path, course_name: str, started_at: datetime,
                          extension: str, current_path: str | None = None) -> Path:
    ext = extension.lower().lstrip(".")
    if ext not in {"m4a", "aac", "wav", "mp3", "ogg", "flac", "opus", "webm"}:
        raise ValueError("不支持的录音文件扩展名")
    stem = recording_stem(course_name, started_at)
    root = root.resolve()
    current = Path(current_path).resolve() if current_path else None
    index = 1
    while True:
        suffix = "" if index == 1 else f" ({index})"
        target = root / f"{stem}{suffix}.{ext}"
        if target == current or not target.exists():
            return target
        index += 1
