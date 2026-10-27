"""ID 生成与时间戳/周次工具（架构设计 §2.2 ``core/ids.py``）。"""

from __future__ import annotations

import re
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime
from typing import Any

__all__ = [
    "new_id",
    "utc_now",
    "to_iso",
    "parse_weeks",
    "local_now",
    "weeks_to_bitmap",
    "bitmap_to_weeks",
    "bitmap_has_week",
    "compress_weeks",
]

_ID_SAFE = re.compile(r"[^a-zA-Z0-9_]+")


def new_id(prefix: str = "") -> str:
    """生成带语义前缀的短 ID，例如 ``rec_3f9a1c2b4d5e``。

    前缀会被规范化为 ``[a-z0-9_]``；为空时返回纯 uuid hex。
    """
    token = uuid.uuid4().hex[:12]
    if not prefix:
        return token
    clean = _ID_SAFE.sub("_", prefix.strip().lower()).strip("_")
    return f"{clean}_{token}" if clean else token


def utc_now() -> datetime:
    """返回带时区的 UTC 当前时间（数据库时间戳统一 UTC）。"""
    return datetime.now(UTC)


def local_now() -> datetime:
    """返回本地时区的当前时间（用于文件名中的 ``YYYY-MM-DD``）。"""
    return datetime.now().astimezone()


def to_iso(dt: datetime | None = None) -> str:
    """将时间序列化为 ISO 8601 字符串（默认当前 UTC 时间）。"""
    value = dt or utc_now()
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.isoformat()


def parse_weeks(spec: Any) -> list[int]:
    """解析周次，返回**去重升序**的周次列表（非法片段被忽略）。

    兼容两种形态（架构设计 v3.3 §3.9.1）：

    - **字符串**（旧格式）：``"1-16"`` / ``"1-8,10-16"`` / ``"3"``；
    - **整数集合**（新模型 ``ScheduleEntry.weeks`` 的存储形态）：``[1, 2, 3, 5]``；
    - ``None`` / 空 → ``[]``。
    """
    weeks: set[int] = set()
    if spec is None:
        return []

    # 整数集合形态（新模型）
    if isinstance(spec, (list, tuple, set, frozenset, range)):
        for item in spec:
            if isinstance(item, bool):  # bool 是 int 子类，排除
                continue
            try:
                value = int(item)
            except (TypeError, ValueError):
                continue
            if value >= 1:
                weeks.add(value)
        return sorted(weeks)

    # 字符串形态（旧格式，亦兼容直接传入 int 的 str() 结果）
    for chunk in str(spec).split(","):
        part = chunk.strip()
        if not part:
            continue
        if "-" in part:
            start_raw, _, end_raw = part.partition("-")
            try:
                start, end = int(start_raw), int(end_raw)
            except ValueError:
                continue
            if start > end:
                start, end = end, start
            weeks.update(range(max(start, 1), end + 1))
        else:
            try:
                week = int(part)
            except ValueError:
                continue
            if week >= 1:
                weeks.add(week)
    return sorted(weeks)


def weeks_to_bitmap(weeks: Iterable[int]) -> int:
    """把周次集合编码为整型位图：第 ``w`` 周 → 第 ``w-1`` 位。

    这是 ``ScheduleEntry.weeks_bitmap`` 的**唯一**生成途径（派生列，禁止手改），
    便于用位运算按周过滤（``bitmap & (1 << (week-1))``）。
    """
    bitmap = 0
    for item in weeks or ():
        if isinstance(item, bool):
            continue
        try:
            value = int(item)
        except (TypeError, ValueError):
            continue
        if value >= 1:
            bitmap |= 1 << (value - 1)
    return bitmap


def bitmap_to_weeks(bitmap: int | None) -> list[int]:
    """位图 → 去重升序周次列表（``weeks_to_bitmap`` 的逆运算）。"""
    value = int(bitmap or 0)
    weeks: list[int] = []
    idx = 1
    while value:
        if value & 1:
            weeks.append(idx)
        value >>= 1
        idx += 1
    return weeks


def bitmap_has_week(bitmap: int | None, week: int) -> bool:
    """判断位图是否包含第 ``week`` 周。"""
    if week < 1:
        return False
    return bool((int(bitmap or 0) >> (week - 1)) & 1)


def compress_weeks(weeks: Iterable[int]) -> str:
    """把周次集合压缩为可读字符串：``[1,2,3,5,6,9] -> "1-3, 5-6, 9"``。

    用于把内部 ``list[int]`` 回吐成人类可读的配置（如 ``CurriculumProfile`` 导出）。
    """
    values: set[int] = set()
    for item in weeks or ():
        if isinstance(item, bool):
            continue
        try:
            value = int(item)
        except (TypeError, ValueError):
            continue
        if value >= 1:
            values.add(value)
    ordered = sorted(values)
    if not ordered:
        return ""
    parts: list[str] = []
    start = prev = ordered[0]
    for cur in ordered[1:]:
        if cur == prev + 1:
            prev = cur
            continue
        parts.append(f"{start}" if start == prev else f"{start}-{prev}")
        start = prev = cur
    parts.append(f"{start}" if start == prev else f"{start}-{prev}")
    return ", ".join(parts)
