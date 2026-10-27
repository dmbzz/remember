"""云端 ASR 用量统计与预算阈值测试（T6-02，FR-17）。"""

from __future__ import annotations

from pathlib import Path
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import AppConfig
from app.db.base import Base
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_db
from app.main import create_app
from app.schemas.usage import UsageRecordCreate
from app.services.usage_service import UsageService


@pytest.fixture
async def usage_env(tmp_path: Path):
    db_file = tmp_path / "test_usage.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)
    db = Database(db_url)
    config = AppConfig()
    svc = UsageService(config=config, database=db)

    app = create_app()

    async def override_get_db():
        async with session_factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_config] = lambda: config
    app.dependency_overrides[get_database_dep] = lambda: db

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield {
            "client": client,
            "svc": svc,
            "db": db,
        }

    await engine.dispose()


@pytest.mark.asyncio
async def test_usage_service_recording_and_summary(usage_env):
    svc: UsageService = usage_env["svc"]

    # 1. 初始为空汇总
    init_sum = await svc.get_summary()
    assert init_sum.total_seconds == 0.0
    assert init_sum.total_requests == 0
    assert init_sum.is_over_budget is False

    # 2. 记录单次转写调用（时长 5400 秒 = 1.5 小时，预估 0.45 元）
    rec1 = await svc.record_usage(
        UsageRecordCreate(
            provider="cloud_api",
            audio_seconds=5400.0,
            est_cost=0.45,
            actual_cost=0.45,
        )
    )
    assert rec1.id.startswith("use_")
    assert rec1.audio_seconds == 5400.0

    # 3. 汇总检查
    sum1 = await svc.get_summary(monthly_budget=50.0)
    assert sum1.total_hours == 1.5
    assert sum1.total_requests == 1
    assert sum1.total_actual_cost == 0.45
    assert sum1.budget_used_percent == round((0.45 / 50.0) * 100, 2)
    assert sum1.is_over_budget is False

    # 4. 预算超额检测
    # 记录一笔超大用量（500小时，150元）
    await svc.record_usage(
        UsageRecordCreate(
            provider="cloud_api",
            audio_seconds=1800000.0,
            est_cost=150.0,
            actual_cost=150.0,
        )
    )
    sum2 = await svc.get_summary(monthly_budget=50.0)
    assert sum2.total_requests == 2
    assert sum2.is_over_budget is True

    # 5. 预算阻断检查
    can_transcribe = await svc.check_budget_available(monthly_budget=50.0)
    assert can_transcribe is False


@pytest.mark.asyncio
async def test_usage_api_endpoints(usage_env):
    client: AsyncClient = usage_env["client"]

    # 1. POST /api/usage/record
    rec_resp = await client.post(
        "/api/usage/record",
        json={
            "provider": "cloud_api",
            "audio_seconds": 3600.0,
            "est_cost": 0.30,
            "actual_cost": 0.30,
        },
    )
    assert rec_resp.status_code == 200
    r_data = rec_resp.json()["data"]
    assert r_data["id"].startswith("use_")
    assert r_data["audio_seconds"] == 3600.0

    # 2. GET /api/usage/summary
    sum_resp = await client.get("/api/usage/summary?monthly_budget=100.0")
    assert sum_resp.status_code == 200
    s_data = sum_resp.json()["data"]
    assert s_data["total_hours"] == 1.0
    assert s_data["total_requests"] == 1
    assert s_data["total_actual_cost"] == 0.30
    assert s_data["is_over_budget"] is False

    # 3. GET /api/usage/records
    list_resp = await client.get("/api/usage/records")
    assert list_resp.status_code == 200
    items = list_resp.json()["data"]
    assert len(items) == 1
    assert items[0]["id"] == r_data["id"]
