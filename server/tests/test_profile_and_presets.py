"""通用配置清单 Profile 与专业预设 Presets 测试。"""

from __future__ import annotations

from pathlib import Path
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.db.base import Base
from app.deps import get_db
from app.main import create_app
from app.schemas.schedule import (
    CurriculumCourseItem,
    CurriculumProfile,
    CurriculumScheduleItem,
    ProfileImportRequest,
)
from app.services.course_service import CourseService
from app.services.profile_service import ProfileService


@pytest.fixture
async def test_db(tmp_path: Path):
    """创建临时测试数据库。"""
    db_file = tmp_path / "test_profile.db"
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


def test_presets_discovery(test_db):
    """验证系统内置专业预设模版发现机制。"""
    # 无需真实 DB
    service = ProfileService(session=None)  # type: ignore
    presets = service.list_presets()
    preset_ids = {p.id for p in presets}

    assert "mechanical" in preset_ids
    assert "cs" in preset_ids
    assert "general_freshman" in preset_ids

    # 查指定预设详情
    cs_preset = service.get_preset("cs")
    assert cs_preset.name == "计算机科学与人工智能（核心课）"
    assert len(cs_preset.courses) == 4
    course_names = [c.name for c in cs_preset.courses]
    assert "数据结构与算法" in course_names
    assert "操作系统" in course_names


def test_time_slot_templates():
    """验证作息节次模版与自动时间推算。"""
    service = ProfileService(session=None)  # type: ignore
    templates = service.get_time_slot_templates()
    assert "standard_830" in templates
    assert "standard_800" in templates

    # 推算大节 1
    start, end = service.resolve_period_time("standard_830", 1)
    assert start == "08:30"
    assert end == "10:05"

    # 推算大节 2
    start2, end2 = service.resolve_period_time("standard_830", 2)
    assert start2 == "10:25"
    assert end2 == "12:00"


async def test_apply_preset_and_export(test_db):
    """测试一键套用专业预设，并导出为配置文件。"""
    async with test_db() as session:
        service = ProfileService(session)

        # 1. 套用机械类预设
        res = await service.apply_preset("mechanical", mode="replace")
        assert res["courses_count"] == 4
        assert res["schedule_entries_count"] == 7

        # 验证数据库中已建好课程
        course_svc = CourseService(session)
        courses = await course_svc.list_courses()
        assert len(courses) == 4
        names = {c.name for c in courses}
        assert "工程力学" in names
        assert "线性代数" in names

        # 2. 导出为 Profile
        exported = await service.export_profile("2026秋")
        assert exported.semester == "2026秋"
        assert len(exported.courses) == 4

        # 3. 导出为 YAML 字符串
        yaml_str = await service.export_profile_yaml("2026秋")
        assert "工程力学" in yaml_str
        assert "线性代数" in yaml_str


async def test_import_custom_student_profile(test_db):
    """测试任意专业学生（如医学生）自定义全新课程的一键导入。"""
    async with test_db() as session:
        service = ProfileService(session)

        # 构造一份医学生的学期课表配置
        medical_profile = CurriculumProfile(
            name="临床医学大二秋季课表",
            major="医学·临床医学",
            semester="2026秋",
            time_slot_template="standard_800",
            courses=[
                CurriculumCourseItem(
                    name="系统解剖学",
                    teacher="赵老师",
                    textbook_ref="系统解剖学_第9版_人卫",
                    schedule=[
                        CurriculumScheduleItem(
                            weekday=1,
                            period=1,  # 不填 start_time/end_time，验证根据 standard_800 自动补全
                            location="解剖大楼301",
                            weeks="1-16",
                        ),
                        CurriculumScheduleItem(
                            weekday=3,
                            period=2,
                            location="解剖实验室",
                            weeks="1-16",
                        ),
                    ],
                ),
                CurriculumCourseItem(
                    name="组织学与胚胎学",
                    teacher="孙老师",
                    textbook_ref="组织学与胚胎学_第9版",
                    schedule=[
                        CurriculumScheduleItem(
                            weekday=2,
                            period=1,
                            location="形态学实验楼",
                            weeks="1-12",
                        )
                    ],
                ),
            ],
        )

        res = await service.import_profile(medical_profile, mode="replace")
        assert res["courses_count"] == 2
        assert res["schedule_entries_count"] == 3

        # 验证自动补齐了 standard_800 的作息时间 (08:00 - 09:40)
        exported = await service.export_profile("2026秋")
        anat = next(c for c in exported.courses if c.name == "系统解剖学")
        assert anat.schedule[0].start_time == "08:00"
        assert anat.schedule[0].end_time == "09:40"
        assert anat.schedule[1].start_time == "10:00"
        assert anat.schedule[1].end_time == "11:40"


async def test_profile_api_endpoints(client: AsyncClient):
    """测试 API 路由：预设列表、一键套用、导出与导入。"""
    # 1. 查询所有预设
    resp = await client.get("/api/schedule/presets")
    assert resp.status_code == 200
    assert resp.json()["code"] == 0
    presets = resp.json()["data"]
    assert len(presets) >= 3

    # 2. 一键套用计算机专业预设
    resp = await client.post("/api/schedule/presets/cs/apply?mode=replace")
    assert resp.status_code == 200
    assert resp.json()["data"]["courses_count"] == 4

    # 3. 查看套用后的课程
    resp = await client.get("/api/courses")
    assert resp.status_code == 200
    assert len(resp.json()["data"]) == 4
    names = {c["name"] for c in resp.json()["data"]}
    assert "数据结构与算法" in names

    # 4. 导出为 JSON
    resp = await client.get("/api/schedule/profile/export")
    assert resp.status_code == 200
    exported = resp.json()["data"]
    assert len(exported["courses"]) == 4

    # 5. 导出为 YAML
    resp = await client.get("/api/schedule/profile/export-yaml")
    assert resp.status_code == 200
    assert "数据结构与算法" in resp.text
