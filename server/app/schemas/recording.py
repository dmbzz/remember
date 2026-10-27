"""录音相关 DTO（架构设计 §3.4、§3.1，T2-01）。"""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "RecordingCreate",
    "RecordingResponse",
    "ChunkUploadResponse",
]


class RecordingCreate(StrictRequestModel):
    """录音登记入参。"""

    course_id: str = Field(..., description="所属课程 ID")
    schedule_entry_id: str | None = Field(None, description="关联课表条目 ID")
    started_at: datetime | None = Field(None, description="录音开始时间")
    ended_at: datetime | None = Field(None, description="录音结束时间")
    duration_ms: int = Field(0, ge=0, description="录音持续时长（毫秒）")
    codec: str = Field("aac", description="音频编码（如 aac, wav, m4a）")
    size_bytes: int = Field(0, ge=0, description="音频预期大小")


class RecordingResponse(BaseModel):
    """录音记录响应体。"""

    model_config = ConfigDict(from_attributes=True)

    id: str
    course_id: str
    course_name: str | None = None
    schedule_entry_id: str | None = None
    started_at: datetime | None = None
    ended_at: datetime | None = None
    duration_ms: int = 0
    file_path: str | None = None
    size_bytes: int = 0
    codec: str = "aac"
    upload_status: Literal["pending", "uploaded"] = "pending"
    transcription_status: Literal["pending", "running", "success", "failed"] = "pending"
    deleted_at: datetime | None = None
    created_at: datetime


class ChunkUploadResponse(BaseModel):
    """分片上传响应体。"""

    recording_id: str
    chunk_index: int
    received_bytes: int
    total_chunks: int | None = None
    is_completed: bool = False
