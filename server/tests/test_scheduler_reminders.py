"""上课提醒与当天日程计算测试（T1-03）。"""

from __future__ import annotations

from datetime import date, datetime
from pathlib import Path
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.db.base import Base
from app.deps import get_db
from app.main import create_app
from app.schemas.schedule import CourseCreate, ScheduleEntryCreate
from app.services.course_service import CourseService
from app.services.schedule_service import ScheduleService
from app.services.scheduler_service import SchedulerReminderService


@pytest.fixture
async def test_db(tmp_path: Path):
    """创建临时测试数据库。"""
    db_file = tmp_path / "test_reminders.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)
    yield session_factory
    await engine.dispose()


@pytest.fixture
async def client(test_db):
    """FastAPI 异步测试客户端。"""
    app = create_app()

    async def override_get_db():
        async with test_db() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = override_get_db
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


def test_week_number_calculation():
    """测试根据开学周一推算教学周。"""
    # 假设开学首周一为 2026-09-07
    start_monday = date(2026, 9, 7)

    # 第 1 周内的周三
    assert (
        SchedulerReminderService.calculate_week_number(
            date(2026, 9, 9), start_monday
        )
        == 1
    )
    # 第 2 周周一
    assert (
        SchedulerReminderService.calculate_week_number(
            date(2026, 9, 14), start_monday
        )
        == 2
    )
    # 第 3 周周五
    assert (
        SchedulerReminderService.calculate_week_number(
            date(2026, 9, 25), start_monday
        )
        == 3
    )


async def test_today_schedule_status(test_db):
    """测试当天课程获取及状态计算。"""
    async with test_db() as session:
        course_svc = CourseService(session)
        sched_svc = ScheduleService(session)
        reminder_svc = SchedulerReminderService(session)

        c1 = await course_svc.create_course(CourseCreate(name="普通物理1"))

        # 假定目标日期是星期一（2026-09-14），添加早上一节课
        await sched_svc.create_entry(
            ScheduleEntryCreate(
                course_id=c1.id,
                weekday=1,
                period=1,
                start_time="08:30",
                end_time="10:05",
                location="理科楼301",
                weeks="1-16",
            )
        )

        target_mon = date(2026, 9, 14)
        start_mon = date(2026, 9, 7)

        resp = await reminder_svc.get_today_schedule(
            target_date=target_mon, semester_start_date=start_mon
        )
        assert resp.weekday == 1
        assert resp.week_number == 2
        assert len(resp.items) == 1
        item = resp.items[0]
        assert item.course_name == "普通物理1"
        assert item.location == "理科楼301"


async def test_reminders_trigger(test_db):
    """测试上课前提醒与正在上课中状态。"""
    async with test_db() as session:
        course_svc = CourseService(session)
        sched_svc = ScheduleService(session)
        reminder_svc = SchedulerReminderService(session)

        c1 = await course_svc.create_course(CourseCreate(name="工程力学"))
        await sched_svc.create_entry(
            ScheduleEntryCreate(
                course_id=c1.id,
                weekday=1,  # 周一
                period=1,
                start_time="09:00",
                end_time="10:30",
                location="机电楼102",
                weeks="1-16",
            )
        )

        start_mon = date(2026, 9, 7)

        # 场景 1：08:48（周一），距 09:00 还有 12 分钟，在 15 分钟提前量内
        time_before = datetime(2026, 9, 14, 8, 48)
        res1 = await reminder_svc.get_reminders(
            lead_minutes=15, now_dt=time_before, semester_start_date=start_mon
        )
        assert len(res1.reminders) == 1
        r1 = res1.reminders[0]
        assert r1.minutes_until_start == 12
        assert r1.is_ongoing is False
        assert "还有 12 分钟上课" in r1.message
        assert "一键开录" in r1.message

        # 场景 2：09:15（周一），09:00 - 10:30 正在上课中
        time_during = datetime(2026, 9, 14, 9, 15)
        res2 = await reminder_svc.get_reminders(
            lead_minutes=15, now_dt=time_during, semester_start_date=start_mon
        )
        assert len(res2.reminders) == 1
        r2 = res2.reminders[0]
        assert r2.is_ongoing is True
        assert "正在上课中" in r2.message

        # 场景 3：11:00（周一），已下课，无提醒
        time_after = datetime(2026, 9, 14, 11, 0)
        res3 = await reminder_svc.get_reminders(
            lead_minutes=15, now_dt=time_after, semester_start_date=start_mon
        )
        assert len(res3.reminders) == 0


async def test_schedule_reminder_api_endpoints(client: AsyncClient):
    """测试 /api/schedule/today 与 /api/schedule/reminders 路由。"""
    # 1. 初始空日程查询
    resp = await client.get("/api/schedule/today")
    assert resp.status_code == 200
    assert resp.json()["code"] == 0
    assert "weekday" in resp.json()["data"]

    # 2. 初始提醒查询
    resp = await client.get("/api/schedule/reminders?lead_minutes=15")
    assert resp.status_code == 200
    assert resp.json()["code"] == 0
    assert "reminders" in resp.json()["data"]
