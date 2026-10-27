"""用量统计与限额 DTO（架构设计 §3.4、T6-02，FR-17）。"""

from __future__ import annotations

from datetime import datetime
from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import StrictRequestModel


class UsageRecordCreate(StrictRequestModel):
    provider: str = "cloud_api"
    audio_seconds: float = Field(..., ge=0.0)
    est_cost: float = Field(default=0.0, ge=0.0)
    actual_cost: float = Field(default=0.0, ge=0.0)


class UsageRecordDTO(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    ts: datetime
    provider: str
    audio_seconds: float
    request_count: int
    est_cost: float
    actual_cost: float


class UsageSummaryDTO(BaseModel):
    total_seconds: float
    total_hours: float
    total_requests: int
    total_estimated_cost: float
    total_actual_cost: float
    monthly_budget: float
    budget_used_percent: float
    is_over_budget: bool
    currency: str = "CNY"
