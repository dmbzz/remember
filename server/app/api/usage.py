"""云 ASR 用量统计与预算路由（架构设计 §3.4、T6-02，FR-17）。"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query

from app.config import AppConfig
from app.db.session import Database
from app.deps import get_config, get_database_dep
from app.schemas.common import ok
from app.schemas.usage import UsageRecordCreate, UsageRecordDTO, UsageSummaryDTO
from app.services.usage_service import UsageService

__all__ = ["router"]

router = APIRouter(prefix="/usage", tags=["usage"])


@router.post("/record", summary="记录单次云 ASR 调用的用量与费用")
async def record_usage(
    payload: UsageRecordCreate,
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    svc = UsageService(config=config, database=database)
    dto = await svc.record_usage(payload)
    return ok(dto.model_dump())


@router.get("/summary", summary="查询用量汇总与预算阈值")
async def get_usage_summary(
    monthly_budget: float | None = Query(None, description="自定义月度预算上限（CNY）"),
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    svc = UsageService(config=config, database=database)
    summary = await svc.get_summary(monthly_budget=monthly_budget)
    return ok(summary.model_dump())


@router.get("/records", summary="查询最近用量明细")
async def list_usage_records(
    limit: int = Query(50, ge=1, le=200),
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    svc = UsageService(config=config, database=database)
    records = await svc.list_records(limit=limit)
    return ok([r.model_dump() for r in records])
