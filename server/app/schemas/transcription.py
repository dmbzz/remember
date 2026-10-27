"""转写相关 DTO（架构设计 §3.4、§3.1，T2-02、T2-03）。"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "TranscriptionCreateRequest",
    "TranscriptErrataItem",
    "TranscriptResponse",
    "TranscriptionTaskResponse",
]


class TranscriptionCreateRequest(StrictRequestModel):
    """提交转写任务请求。"""

    recording_id: str = Field(..., description="录音记录 ID")
    provider: str | None = Field(None, description="指定转写 Provider（如 local_gpu, cloud_api）")
    lesson: int | None = Field(None, description="课次编号（如第 N 次课，不传则自动顺推）")


class TranscriptErrataItem(BaseModel):
    """勘误表条目。"""

    original: str = Field(..., description="转写原文中的错词/噪音")
    corrected: str = Field(..., description="学科知识纠正后的正确术语")
    context: str | None = Field(None, description="上下文语境摘要")


class TranscriptResponse(BaseModel):
    """转写结果详情响应体。"""

    model_config = ConfigDict(from_attributes=True)

    id: str
    recording_id: str
    provider: str
    raw_text: str
    corrected_text: str | None = None
    errata: list[dict[str, Any]] = Field(default_factory=list)
    language: str = "zh"
    duration_sec: float = 0.0
    archive_path: str | None = None
    created_at: datetime


class TranscriptionTaskResponse(BaseModel):
    """转写任务状态响应体。"""

    task_id: str
    recording_id: str
    status: str
    error: str | None = None
    transcript_id: str | None = None
    created_at: str | None = None
