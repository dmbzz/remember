"""按笔记标题或文件名中的时间顺序进行排序。"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from app.schemas.note import NoteDTO

_DATE_SUFFIX = re.compile(r"_(\d{4}-\d{2}-\d{2})$")
_SEP_DATETIME = re.compile(
    r"(?<!\d)((?:19|20)\d{2})[-./年](0?[1-9]|1[0-2])[-./月](0?[1-9]|[12]\d|3[01])日?"
    r"(?:[T _-]+([01]?\d|2[0-3])[:：-]([0-5]\d)(?:[:：-]([0-5]\d))?)?(?!\d)"
)
_COMPACT_DATETIME = re.compile(
    r"(?<!\d)((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)"
    r"(?:[T _-]+([01]\d|2[0-3])[:：-]?([0-5]\d))?"
)


def _build_dt(
    year: int,
    month: int,
    day: int,
    hour: int = 0,
    minute: int = 0,
    second: int = 0,
) -> tuple[datetime, str] | None:
    try:
        dt = datetime(year, month, day, hour, minute, second, tzinfo=timezone.utc)
    except ValueError:
        return None
    return dt, f"{year:04d}-{month:02d}-{day:02d}"


def extract_date_from_text(text: str | None) -> tuple[datetime, str] | None:
    """从标题或文件名中提取合法日期时间，优先匹配末尾 `_YYYY-MM-DD`。"""
    if not text:
        return None
    raw = text.strip()
    if not raw:
        return None

    suffix_match = _DATE_SUFFIX.search(raw)
    if suffix_match:
        year, month, day = map(int, suffix_match.group(1).split("-"))
        parsed = _build_dt(year, month, day)
        if parsed is not None:
            return parsed

    for match in _SEP_DATETIME.finditer(raw):
        year, month, day = int(match.group(1)), int(match.group(2)), int(match.group(3))
        hour = int(match.group(4)) if match.group(4) is not None else 0
        minute = int(match.group(5)) if match.group(5) is not None else 0
        second = int(match.group(6)) if match.group(6) is not None else 0
        parsed = _build_dt(year, month, day, hour, minute, second)
        if parsed is not None:
            return parsed

    for match in _COMPACT_DATETIME.finditer(raw):
        year, month, day = int(match.group(1)), int(match.group(2)), int(match.group(3))
        hour = int(match.group(4)) if match.group(4) is not None else 0
        minute = int(match.group(5)) if match.group(5) is not None else 0
        parsed = _build_dt(year, month, day, hour, minute)
        if parsed is not None:
            return parsed

    return None


def extract_note_title_time(
    topic: str | None,
    class_date: str | None,
    path: str | None,
) -> datetime | None:
    """按 class_date → topic → 文件名 stem 的优先级提取笔记标题时间。"""
    for candidate in (class_date, topic):
        parsed = extract_date_from_text(candidate)
        if parsed is not None:
            return parsed[0]
    if path:
        stem = Path(path.replace("\\", "/")).stem
        parsed = extract_date_from_text(stem)
        if parsed is not None:
            return parsed[0]
    return None


def _updated_ts(item: NoteDTO) -> float:
    dt = item.updated_at or item.created_at
    if dt is None:
        return 0.0
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def sort_notes_by_title_time(
    items: list[NoteDTO],
    *,
    descending: bool = True,
) -> list[NoteDTO]:
    """按标题时间顺序排序；无日期笔记始终排在末尾并按更新时间/标题稳定兜底。"""
    dated: list[tuple[datetime, NoteDTO]] = []
    undated: list[NoteDTO] = []

    for item in items:
        title_dt = extract_note_title_time(item.topic, item.class_date, item.obsidian_path)
        if title_dt is not None:
            dated.append((title_dt, item))
        else:
            undated.append(item)

    dated.sort(
        key=lambda pair: (
            pair[0].timestamp(),
            pair[1].lesson if pair[1].lesson is not None else (-1 if descending else 1 << 30),
        ),
        reverse=descending,
    )
    # 同一时间与课次内部按 updated_at 降序、标题/ID 升序稳定排列
    # 先稳定排序兜底键，再排主键
    dated.sort(key=lambda pair: (pair[1].topic.casefold(), pair[1].note_id))
    dated.sort(key=lambda pair: _updated_ts(pair[1]), reverse=True)
    dated.sort(
        key=lambda pair: (
            pair[0].timestamp(),
            pair[1].lesson if pair[1].lesson is not None else (-1 if descending else 1 << 30),
        ),
        reverse=descending,
    )

    undated.sort(key=lambda item: (item.topic.casefold(), item.note_id))
    undated.sort(key=_updated_ts, reverse=True)
    return [pair[1] for pair in dated] + undated
