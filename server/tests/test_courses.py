"""课程管理 API 与服务测试（T1-01）。"""

from __future__ import annotations

from pathlib import Path
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.db.base import Base
from app.db.session import Database, get_session
from app.deps import get_db
from app.main import create_app
from app.schemas.schedule import CourseCreate, CourseUpdate
from app.services.course_service import CourseService, DEFAULT_COURSES


@pytest.fixture
async def test_db(tmp_path: Path):
    """创建临时 SQLite 数据库并建表。"""
    db_file = tmp_path / "test_courses.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)

    yield session_factory

    await engine.dispose()


@pytest.fixture
async def client(test_db):
    """FastAPI 异步测试客户端，重载 get_db 依赖。"""
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


async def test_course_service_crud(test_db):
    """测试 CourseService 原生异步 CRUD。"""
    async with test_db() as session:
        service = CourseService(session)

        # 初始为空
        courses = await service.list_courses()
        assert len(courses) == 0

        # 新增
        c1 = await service.create_course(
            CourseCreate(name="工程力学", semester="2026秋", teacher="张老师")
        )
        assert c1.id.startswith("course_")
        assert c1.name == "工程力学"

        # 重复创建报错
        with pytest.raises(Exception) as exc:
            await service.create_course(CourseCreate(name="工程力学"))
        assert "已存在" in str(exc.value)

        # 更新
        updated = await service.update_course(c1.id, CourseUpdate(teacher="王老师"))
        assert updated.teacher == "王老师"

        # 查单条
        fetched = await service.get_course(c1.id)
        assert fetched.teacher == "王老师"

        # 删除
        await service.delete_course(c1.id)
        assert len(await service.list_courses()) == 0


async def test_ensure_default_courses(test_db):
    """测试 4 门预置核心课程初始化。"""
    async with test_db() as session:
        service = CourseService(session)
        defaults = await service.ensure_default_courses()
        assert len(defaults) == 4
        names = {c.name for c in defaults}
        for item in DEFAULT_COURSES:
            assert item["name"] in names

        # 再次执行幂等
        again = await service.ensure_default_courses()
        assert len(again) == 4


async def test_courses_api_endpoints(client: AsyncClient):
    """测试 /api/courses 路由交互。"""
    # 初始获取
    resp = await client.get("/api/courses")
    assert resp.status_code == 200
    assert resp.json()["code"] == 0
    assert resp.json()["data"] == []

    # 初始化默认课程
    resp = await client.post("/api/courses/init-defaults")
    assert resp.status_code == 200
    assert len(resp.json()["data"]) == 4

    # 新建课程
    resp = await client.post(
        "/api/courses",
        json={"name": "机械制图", "semester": "2026秋", "teacher": "刘老师"},
    )
    assert resp.status_code == 200
    course_id = resp.json()["data"]["id"]

    # 查询单条
    resp = await client.get(f"/api/courses/{course_id}")
    assert resp.status_code == 200
    assert resp.json()["data"]["name"] == "机械制图"

    # 更新
    resp = await client.put(f"/api/courses/{course_id}", json={"teacher": "陈老师"})
    assert resp.status_code == 200
    assert resp.json()["data"]["teacher"] == "陈老师"

    # 删除
    resp = await client.delete(f"/api/courses/{course_id}")
    assert resp.status_code == 200

    # 验证删除后 404
    resp = await client.get(f"/api/courses/{course_id}")
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# FR-33：课程级「自动录音」开关（auto_record）—— 能写能读（防静默丢弃）
# ---------------------------------------------------------------------------


async def test_course_auto_record_persist_and_read(test_db):
    """服务层：auto_record 能存能读（默认 False；写 True → 读回 True → 再关回 False）。"""
    async with test_db() as session:
        service = CourseService(session)

        # 默认关闭
        c = await service.create_course(CourseCreate(name="工程力学"))
        assert c.auto_record is False

        fetched = await service.get_course(c.id)
        assert fetched.auto_record is False

        # 打开
        updated = await service.update_course(c.id, CourseUpdate(auto_record=True))
        assert updated.auto_record is True
        assert (await service.get_course(c.id)).auto_record is True

        # 关闭
        updated = await service.update_course(c.id, CourseUpdate(auto_record=False))
        assert updated.auto_record is False
        assert (await service.get_course(c.id)).auto_record is False

        # 创建时直接指定
        c2 = await service.create_course(CourseCreate(name="线性代数", auto_record=True))
        assert c2.auto_record is True


async def test_course_auto_record_api_round_trip(client: AsyncClient):
    """API 层：PUT /api/courses/{id} {"auto_record": true} 必须真正落库并被 GET 读回。"""
    resp = await client.post("/api/courses", json={"name": "电工电子", "auto_record": False})
    assert resp.status_code == 200
    course_id = resp.json()["data"]["id"]
    assert resp.json()["data"]["auto_record"] is False

    # 打开自动录音
    resp = await client.put(f"/api/courses/{course_id}", json={"auto_record": True})
    assert resp.status_code == 200
    assert resp.json()["data"]["auto_record"] is True

    # 重新查询，确认持久化（而非仅回显）
    resp = await client.get(f"/api/courses/{course_id}")
    assert resp.status_code == 200
    assert resp.json()["data"]["auto_record"] is True

    # 列表接口也应带该字段
    resp = await client.get("/api/courses")
    assert resp.status_code == 200
    row = next(c for c in resp.json()["data"] if c["id"] == course_id)
    assert row["auto_record"] is True
