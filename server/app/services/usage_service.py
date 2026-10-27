"""云端转写用量统计与预算阈值控制服务（架构设计 §3.4、T6-02，FR-17）。"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from sqlalchemy import func, select

from app.config import AppConfig, get_app_config
from app.db.models import UsageRecord
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.schemas.usage import UsageRecordCreate, UsageRecordDTO, UsageSummaryDTO

__all__ = ["UsageService"]


class UsageService:
    """用量统计与阈值告警服务。"""

    # 默认月度预算软限额（单位：CNY）
    DEFAULT_MONTHLY_BUDGET: float = 100.0

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()

    async def record_usage(self, req: UsageRecordCreate) -> UsageRecordDTO:
        """记录单次云 ASR 调用的音频时长与费用。"""
        now_dt = datetime.now(timezone.utc)
        async with self.database.session_scope() as session:
            record = UsageRecord(
                ts=now_dt,
                provider=req.provider,
                audio_seconds=req.audio_seconds,
                request_count=1,
                est_cost=req.est_cost,
                actual_cost=req.actual_cost,
            )
            session.add(record)
            await session.flush()

            return UsageRecordDTO(
                id=record.id,
                ts=record.ts,
                provider=record.provider,
                audio_seconds=record.audio_seconds,
                request_count=record.request_count,
                est_cost=record.est_cost,
                actual_cost=record.actual_cost,
            )

    async def get_summary(self, monthly_budget: float | None = None) -> UsageSummaryDTO:
        """聚合查询历史与当月用量统计及预算使用比例。"""
        budget = monthly_budget if monthly_budget is not None else self.DEFAULT_MONTHLY_BUDGET

        async with self.database.session_scope() as session:
            stmt = select(
                func.coalesce(func.sum(UsageRecord.audio_seconds), 0.0),
                func.coalesce(func.sum(UsageRecord.request_count), 0),
                func.coalesce(func.sum(UsageRecord.est_cost), 0.0),
                func.coalesce(func.sum(UsageRecord.actual_cost), 0.0),
            )
            res = await session.execute(stmt)
            tot_sec, tot_req, tot_est, tot_act = res.one()

            tot_sec = float(tot_sec)
            tot_req = int(tot_req)
            tot_est = round(float(tot_est), 4)
            tot_act = round(float(tot_act), 4)
            tot_hours = round(tot_sec / 3600.0, 2)

            cost_to_check = tot_act if tot_act > 0.0 else tot_est
            pct = round((cost_to_check / budget) * 100.0, 2) if budget > 0.0 else 0.0
            is_over = cost_to_check >= budget

            return UsageSummaryDTO(
                total_seconds=tot_sec,
                total_hours=tot_hours,
                total_requests=tot_req,
                total_estimated_cost=tot_est,
                total_actual_cost=tot_act,
                monthly_budget=budget,
                budget_used_percent=pct,
                is_over_budget=is_over,
                currency="CNY",
            )

    async def check_budget_available(self, monthly_budget: float | None = None) -> bool:
        """检查是否超出月度预算，用于阻断高额扣费。"""
        summary = await self.get_summary(monthly_budget)
        return not summary.is_over_budget

    async def list_records(self, limit: int = 50) -> list[UsageRecordDTO]:
        """查询最近的用量明细记录。"""
        async with self.database.session_scope() as session:
            stmt = select(UsageRecord).order_by(UsageRecord.ts.desc()).limit(limit)
            res = await session.execute(stmt)
            rows = res.scalars().all()
            return [
                UsageRecordDTO(
                    id=r.id,
                    ts=r.ts,
                    provider=r.provider,
                    audio_seconds=r.audio_seconds,
                    request_count=r.request_count,
                    est_cost=r.est_cost,
                    actual_cost=r.actual_cost,
                )
                for r in rows
            ]
