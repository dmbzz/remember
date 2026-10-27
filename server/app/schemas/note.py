"""课堂笔记数据传输模型（DTO）。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "NoteContentResponse",
    "NoteDTO",
    "NoteGenerateRequest",
    "NoteListResponse",
]


class NoteGenerateRequest(StrictRequestModel):
    """触发笔记生成请求。"""

    course_name: str = Field(..., description="课程名称，如'自动控制原理'")
    lesson: int = Field(default=1, description="第 N 次课")
    class_date: str = Field(..., description="上课日期，格式 YYYY-MM-DD")
    topic: str | None = Field(default=None, description="课程主题/关键词；若不提供则由 LLM 提取")
    transcript_id: str | None = Field(default=None, description="转写记录 ID")
    recording_id: str | None = Field(default=None, description="录音记录 ID")
    courseware_id: str | None = Field(default=None, description="关联课件 ID（可选）")
    backfill: bool = Field(default=False, description="是否尝试教材内容回填")


class NoteDTO(BaseModel):
    """笔记元数据快照。"""

    id: str
    note_id: str
    course_name: str
    lesson: int | None = None
    topic: str
    class_date: str | None = None
    format: str = "融合式（课堂实录 + 拓展讲解）"
    obsidian_path: str | None = None
    content_hash: str | None = None
    origin: str = "win"
    deleted: bool = False
    marker_stats: dict[str, int] = Field(default_factory=dict)
    created_at: datetime
    updated_at: datetime


class NoteContentResponse(BaseModel):
    """笔记全文与统计响应。"""

    note: NoteDTO
    markdown: str
    marker_stats: dict[str, int] = Field(default_factory=dict)


class NoteListResponse(BaseModel):
    """笔记列表响应。"""

    items: list[NoteDTO] = Field(default_factory=list)
    total: int = 0
