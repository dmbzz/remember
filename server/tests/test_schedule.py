"""课表管理与 OCR 导入测试（T1-01、T1-02）。"""

from __future__ import annotations

import io
from datetime import date
from pathlib import Path
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.api.schedule import _schedule_service
from app.core.ids import bitmap_has_week, compress_weeks, parse_weeks, weeks_to_bitmap
from app.db.base import Base
from app.db.models import ScheduleEntry
from app.deps import get_db
from app.errors import ApiError, ErrorCode, ProviderError
from app.main import create_app
from app.providers.base import ProviderCapabilities, VisionProvider
from app.schemas.schedule import (
    CourseCreate,
    ScheduleConfirmItem,
    ScheduleConfirmRequest,
    ScheduleEntryCreate,
    ScheduleEntryUpdate,
)
from app.services.course_service import CourseService
from app.services.schedule_service import ScheduleService
from sqlalchemy import select


class DummyVisionProvider(VisionProvider):
    """用于测试课表截图 OCR 解析的模拟视觉 Provider。"""

    default_name = "dummy_vision"

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(name=self.name, kind="vision", runs_offline=True)

    async def read_image(self, image_path: str, prompt: str) -> str:
        return """
        [
            {
                "course_name": "工程力学",
                "teacher": "张教授",
                "weekday": 1,
                "period": 1,
                "start_time": "08:00",
                "end_time": "09:35",
                "location": "一教201",
                "weeks": "1-16"
            },
            {
                "course_name": "普通物理1",
                "teacher": "王教授",
                "weekday": 2,
                "period": 2,
                "start_time": "09:55",
                "end_time": "11:30",
                "location": "物理楼302",
                "weeks": "1-8"
            }
        ]
        """

    async def read_pages(self, pdf_path: str, pages: list[int], prompt: str) -> list[str]:
        return []


class FailingVisionProvider(VisionProvider):
    """模拟视觉 Provider **调用失败**（抛 ProviderError）——用于验证错误不再被吞。"""

    default_name = "failing_vision"

    def __init__(
        self,
        config,
        provider_name: str | None = None,
        *,
        code: int = ErrorCode.PROVIDER_CALL_FAILED,
        message: str = "视觉读取失败：连接超时",
        retryable: bool = True,
    ) -> None:
        super().__init__(config, provider_name)
        self._code = code
        self._message = message
        self._retryable = retryable

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(name=self.name, kind="vision")

    async def read_image(self, image_path: str, prompt: str) -> str:
        raise ProviderError(
            self._message, provider=self.name, code=self._code, retryable=self._retryable
        )

    async def read_pages(self, pdf_path: str, pages: list[int], prompt: str) -> list[str]:
        return []


class RawTextVisionProvider(VisionProvider):
    """视觉 Provider 调用**成功**但返回不可解析的原文（用于测试 empty / unstructured）。"""

    default_name = "raw_vision"

    def __init__(self, config, provider_name: str | None = None, *, text: str = "") -> None:
        super().__init__(config, provider_name)
        self._text = text

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(name=self.name, kind="vision")

    async def read_image(self, image_path: str, prompt: str) -> str:
        return self._text

    async def read_pages(self, pdf_path: str, pages: list[int], prompt: str) -> list[str]:
        return []


@pytest.fixture
async def test_db(tmp_path: Path):
    """创建临时测试数据库。"""
    db_file = tmp_path / "test_schedule.db"
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


@pytest.fixture
async def app_and_client(test_db):
    """返回 (app, client)，便于在用例中覆盖 ``_schedule_service`` 依赖注入故障 Provider。"""
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
        yield app, ac


async def test_schedule_service_crud_and_weeks(test_db):
    """测试课表条目增删改查与周次动态过滤。"""
    async with test_db() as session:
        course_svc = CourseService(session)
        schedule_svc = ScheduleService(session)

        c1 = await course_svc.create_course(CourseCreate(name="线性代数"))

        # 添加条目：周一第 1 节，第 1-8 周
        e1 = await schedule_svc.create_entry(
            ScheduleEntryCreate(
                course_id=c1.id,
                weekday=1,
                period=1,
                start_time="08:00",
                end_time="09:35",
                weeks="1-8",
            )
        )
        assert e1.id.startswith("sch_")

        # 添加条目：周一第 2 节，第 10-16 周
        e2 = await schedule_svc.create_entry(
            ScheduleEntryCreate(
                course_id=c1.id,
                weekday=1,
                period=2,
                start_time="09:55",
                end_time="11:30",
                weeks="10-16",
            )
        )

        # 查所有周一的课
        all_mon = await schedule_svc.list_entries(weekday=1)
        assert len(all_mon) == 2

        # 动态过滤：第 3 周（应只有 e1）
        w3_entries = await schedule_svc.list_entries(weekday=1, week=3)
        assert len(w3_entries) == 1
        assert w3_entries[0].id == e1.id

        # 动态过滤：第 12 周（应只有 e2）
        w12_entries = await schedule_svc.list_entries(weekday=1, week=12)
        assert len(w12_entries) == 1
        assert w12_entries[0].id == e2.id

        # 动态过滤：第 9 周（无课）
        w9_entries = await schedule_svc.list_entries(weekday=1, week=9)
        assert len(w9_entries) == 0

        # 更新
        updated = await schedule_svc.update_entry(e1.id, ScheduleEntryUpdate(location="理学楼101"))
        assert updated.location == "理学楼101"

        # 删除
        await schedule_svc.delete_entry(e1.id)
        assert len(await schedule_svc.list_entries(weekday=1)) == 1


async def test_schedule_ocr_and_confirm(test_db):
    """测试课表截图 OCR 解析与批量确认入库。"""
    dummy_vision = DummyVisionProvider(config=None)
    async with test_db() as session:
        schedule_svc = ScheduleService(session, vision_provider=dummy_vision)

        # 1. OCR 提取
        ocr_res = await schedule_svc.ocr_import("dummy_path.png")
        assert len(ocr_res.items) == 2
        assert ocr_res.items[0].course_name == "工程力学"
        assert ocr_res.items[1].course_name == "普通物理1"
        assert ocr_res.status == "ok"  # 正常路径不受本次修复影响

        # 2. 批量确认入库
        confirm_req = ScheduleConfirmRequest(
            semester="2026秋",
            entries=[
                ScheduleConfirmItem(
                    course_name="工程力学",
                    teacher="张教授",
                    weekday=1,
                    period=1,
                    start_time="08:00",
                    end_time="09:35",
                    location="一教201",
                    weeks="1-16",
                ),
                ScheduleConfirmItem(
                    course_name="普通物理1",
                    teacher="王教授",
                    weekday=2,
                    period=2,
                    start_time="09:55",
                    end_time="11:30",
                    location="物理楼302",
                    weeks="1-8",
                ),
            ],
        )

        entries = await schedule_svc.confirm_entries(confirm_req)
        assert len(entries) == 2
        assert all(e.confirmed is True for e in entries)
        assert all(e.source == "ocr" for e in entries)

        # 验证自动新建了课程
        course_svc = CourseService(session)
        c_list = await course_svc.list_courses()
        assert len(c_list) == 2
        c_names = {c.name for c in c_list}
        assert "工程力学" in c_names
        assert "普通物理1" in c_names


async def test_schedule_api_endpoints(client: AsyncClient):
    """测试 /api/schedule 路由操作。"""
    # 1. 先创建一门课程
    c_resp = await client.post("/api/courses", json={"name": "电工电子"})
    course_id = c_resp.json()["data"]["id"]

    # 2. 录入课表条目
    entry_payload = {
        "course_id": course_id,
        "weekday": 3,
        "period": 1,
        "start_time": "14:00",
        "end_time": "15:35",
        "location": "实验楼401",
        "weeks": "1-16",
    }
    resp = await client.post("/api/schedule", json=entry_payload)
    assert resp.status_code == 200
    entry_id = resp.json()["data"]["id"]
    assert resp.json()["data"]["course_name"] == "电工电子"

    # 3. 按周次过滤查询
    resp = await client.get("/api/schedule?week=5")
    assert resp.status_code == 200
    assert len(resp.json()["data"]) == 1

    resp = await client.get("/api/schedule?week=20")
    assert resp.status_code == 200
    assert len(resp.json()["data"]) == 0

    # 4. 更新条目
    resp = await client.put(f"/api/schedule/{entry_id}", json={"location": "实验楼402"})
    assert resp.status_code == 200
    assert resp.json()["data"]["location"] == "实验楼402"

    # 5. 删除条目
    resp = await client.delete(f"/api/schedule/{entry_id}")
    assert resp.status_code == 200


async def test_reschedule_one_occurrence_keeps_other_weeks(client: AsyncClient):
    course = (await client.post("/api/courses", json={"name": "工程力学"})).json()["data"]
    original = (await client.post("/api/schedule", json={
        "course_id": course["id"], "weekday": 5, "period": 1,
        "start_time": "08:15", "end_time": "09:50",
        "location": "教学楼4-402", "weeks": [6, 7],
    })).json()["data"]
    payload = {
        "semester_start": "2026-08-31",
        "source_date": "2026-10-09",  # 第 6 周周五
        "target_date": "2026-10-14",  # 第 7 周周三
    }
    response = await client.post(
        f"/api/schedule/{original['id']}/reschedule", json=payload
    )
    assert response.status_code == 200
    moved = response.json()["data"]
    assert moved["id"] != original["id"]
    assert moved["weekday"] == 3
    assert moved["weeks"] == [7]
    assert moved["location"] == "教学楼4-402"
    assert moved["start_time"] == "08:15"
    assert (await client.get("/api/schedule?week=6")).json()["data"] == []
    remaining = (await client.get("/api/schedule?week=7")).json()["data"]
    assert {(e["weekday"], e["id"]) for e in remaining} == {
        (5, original["id"]), (3, moved["id"])
    }
    conflict = await client.post(
        f"/api/schedule/{original['id']}/reschedule",
        json={**payload, "source_date": "2026-10-16", "target_date": "2026-10-14"},
    )
    assert conflict.status_code == 409


async def test_reschedule_single_week_updates_existing_entry(client: AsyncClient):
    course = (await client.post("/api/courses", json={"name": "普通物理"})).json()["data"]
    original = (await client.post("/api/schedule", json={
        "course_id": course["id"], "weekday": 5, "period": 1, "weeks": [6],
    })).json()["data"]
    response = await client.post(f"/api/schedule/{original['id']}/reschedule", json={
        "semester_start": "2026-08-31", "source_date": "2026-10-09",
        "target_date": "2026-10-12",
    })
    assert response.status_code == 200
    assert response.json()["data"]["id"] == original["id"]
    assert response.json()["data"]["weeks"] == [7]
    assert response.json()["data"]["weekday"] == 1
    assert len((await client.get("/api/schedule")).json()["data"]) == 1


# ---------------------------------------------------------------------------
# BugFix：课表 OCR 静默失败 —— 让错误可见（服务层）
# ---------------------------------------------------------------------------


async def test_ocr_vision_none_raises_unavailable(test_db):
    """未装配视觉 Provider → 明确「未配置」错误，而非返回空列表 200。"""
    async with test_db() as session:
        svc = ScheduleService(session, vision_provider=None)
        with pytest.raises(ApiError) as ei:
            await svc.ocr_import("x.png")
        assert ei.value.code == ErrorCode.VISION_PROVIDER_UNAVAILABLE
        assert "未配置" in ei.value.message
        assert "cloud_vision" in ei.value.message


async def test_ocr_vision_call_failed_raises(test_db):
    """视觉 Provider 调用失败 → 抛 VISION_CALL_FAILED，消息带原始异常类型与摘要。"""
    async with test_db() as session:
        svc = ScheduleService(
            session,
            vision_provider=FailingVisionProvider(
                None, code=ErrorCode.PROVIDER_CALL_FAILED, message="视觉读取失败：连接超时 timeout"
            ),
        )
        with pytest.raises(ApiError) as ei:
            await svc.ocr_import("x.png")
        assert ei.value.code == ErrorCode.VISION_CALL_FAILED
        assert "ProviderError" in ei.value.message
        assert "连接超时" in ei.value.message


async def test_ocr_vision_missing_key_maps_to_unavailable(test_db):
    """视觉 Provider 因「未配置 api_key」失败 → 归为「未配置/不可用」，且对密钥脱敏。"""
    async with test_db() as session:
        svc = ScheduleService(
            session,
            vision_provider=FailingVisionProvider(
                None,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                message="视觉 Provider[cloud_vision] 未配置 api_key sk-1234567890abcdef",
                retryable=False,
            ),
        )
        with pytest.raises(ApiError) as ei:
            await svc.ocr_import("x.png")
        assert ei.value.code == ErrorCode.VISION_PROVIDER_UNAVAILABLE
        assert "api_key" in ei.value.message
        assert "sk-1234567890abcdef" not in ei.value.message  # 脱敏
        assert "***" in ei.value.message


async def test_ocr_generic_exception_raises_call_failed(test_db):
    """任意非 ProviderError 异常也不得被吞。"""

    class BoomVision(VisionProvider):
        default_name = "boom_vision"

        def capabilities(self) -> ProviderCapabilities:
            return ProviderCapabilities(name=self.name, kind="vision")

        async def read_image(self, image_path: str, prompt: str) -> str:
            raise RuntimeError("底层解码失败")

        async def read_pages(self, pdf_path: str, pages: list[int], prompt: str) -> list[str]:
            return []

    async with test_db() as session:
        svc = ScheduleService(session, vision_provider=BoomVision(None))
        with pytest.raises(ApiError) as ei:
            await svc.ocr_import("x.png")
        assert ei.value.code == ErrorCode.VISION_CALL_FAILED
        assert "RuntimeError" in ei.value.message


async def test_ocr_unstructured_when_text_not_parseable(test_db):
    """视觉成功但文本无法结构化 → 正常返回，status=unstructured 且 raw_text 非空。"""
    async with test_db() as session:
        svc = ScheduleService(
            session,
            vision_provider=RawTextVisionProvider(None, text="这是一张图片但没有清晰课表"),
            llm_provider=None,  # LLM 兜底不可用
        )
        res = await svc.ocr_import("x.png")
        assert res.items == []
        assert res.raw_text == "这是一张图片但没有清晰课表"
        assert res.status == "unstructured"
        assert res.notice


async def test_ocr_empty_when_vision_returns_nothing(test_db):
    """视觉成功但返回空文本 → 正常返回，status=empty。"""
    async with test_db() as session:
        svc = ScheduleService(session, vision_provider=RawTextVisionProvider(None, text=""))
        res = await svc.ocr_import("x.png")
        assert res.items == []
        assert res.raw_text == ""
        assert res.status == "empty"
        assert res.notice


# ---------------------------------------------------------------------------
# BugFix：课表 OCR 静默失败 —— API 层（HTTP 状态 + 错误码）
# ---------------------------------------------------------------------------


async def test_ocr_api_call_failed_returns_error(app_and_client, test_db):
    """/api/schedule/ocr 视觉调用失败时返回 HTTP 502 + VISION_CALL_FAILED，而非 200 空列表。"""
    app, ac = app_and_client
    app.dependency_overrides[_schedule_service] = lambda: ScheduleService(
        None,
        vision_provider=FailingVisionProvider(None, code=ErrorCode.PROVIDER_CALL_FAILED),
        llm_provider=None,
    )
    resp = await ac.post(
        "/api/schedule/ocr", files={"file": ("s.png", io.BytesIO(b"fake"), "image/png")}
    )
    assert resp.status_code == 502
    body = resp.json()
    assert body["code"] == int(ErrorCode.VISION_CALL_FAILED)
    assert body["message"]


async def test_ocr_api_not_configured_returns_503(app_and_client, test_db):
    """未装配视觉 Provider 时返回 HTTP 503 + VISION_PROVIDER_UNAVAILABLE。"""
    app, ac = app_and_client
    app.dependency_overrides[_schedule_service] = lambda: ScheduleService(
        None, vision_provider=None, llm_provider=None
    )
    resp = await ac.post(
        "/api/schedule/ocr", files={"file": ("s.png", io.BytesIO(b"fake"), "image/png")}
    )
    assert resp.status_code == 503
    body = resp.json()
    assert body["code"] == int(ErrorCode.VISION_PROVIDER_UNAVAILABLE)
    assert "未配置" in body["message"]


async def test_ocr_api_unstructured_still_200_with_notice(app_and_client, test_db):
    """视觉成功但没结构化出条目 → 200，但 message/notice 明确说明「未能结构化」。"""
    app, ac = app_and_client
    app.dependency_overrides[_schedule_service] = lambda: ScheduleService(
        None,
        vision_provider=RawTextVisionProvider(None, text="无课表内容"),
        llm_provider=None,
    )
    resp = await ac.post(
        "/api/schedule/ocr", files={"file": ("s.png", io.BytesIO(b"fake"), "image/png")}
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["data"]["status"] == "unstructured"
    assert body["data"]["notice"]
    assert "未能结构化" in body["message"]


# ---------------------------------------------------------------------------
# v3.3 §3.9.1：weeks → list[int] + weeks_bitmap（派生列，位运算查询）
# ---------------------------------------------------------------------------


async def test_entry_weeks_normalized_and_bitmap(test_db):
    """weeks 存为 list[int]；weeks_bitmap 由 weeks 派生；按周过滤走位运算。"""
    async with test_db() as session:
        course = await CourseService(session).create_course(CourseCreate(name="线性代数"))
        svc = ScheduleService(session)

        # 字符串形态（旧格式）→ 归一为整数集合
        e1 = await svc.create_entry(
            ScheduleEntryCreate(course_id=course.id, weekday=1, period=1, weeks="1-8,10-12")
        )
        assert e1.weeks == [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12]
        assert e1.weeks_bitmap == weeks_to_bitmap([1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12])
        assert bitmap_has_week(e1.weeks_bitmap, 12) is True
        assert bitmap_has_week(e1.weeks_bitmap, 9) is False

        # 集合形态（新模型）
        e2 = await svc.create_entry(
            ScheduleEntryCreate(course_id=course.id, weekday=1, period=2, weeks=[1, 3, 5, 7])
        )
        assert e2.weeks == [1, 3, 5, 7]
        assert e2.weeks_bitmap == weeks_to_bitmap([1, 3, 5, 7])

        # 缺省 → 1-16（放在 weekday=2，避免干扰 weekday=1 的过滤断言）
        e3 = await svc.create_entry(
            ScheduleEntryCreate(course_id=course.id, weekday=2, period=3)
        )
        assert e3.weeks == list(range(1, 17))

        # 位运算按周过滤（weekday=1 上只有 e1/e2）
        assert {e.id for e in await svc.list_entries(weekday=1, week=12)} == {e1.id}
        assert await svc.list_entries(weekday=1, week=9) == []
        assert {e.id for e in await svc.list_entries(weekday=1, week=3)} == {e1.id, e2.id}

        # 更新会重算位图
        updated = await svc.update_entry(e1.id, ScheduleEntryUpdate(weeks="5-6"))
        assert updated.weeks == [5, 6]
        assert updated.weeks_bitmap == weeks_to_bitmap([5, 6])
        assert await svc.list_entries(weekday=1, week=12) == []


def test_weeks_helpers_roundtrip():
    """parse_weeks / weeks_to_bitmap / compress_weeks 纯函数契约。"""
    assert parse_weeks("1-8,10-12") == [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12]
    assert parse_weeks([3, 1, 2, 2]) == [1, 2, 3]
    assert parse_weeks(None) == []
    assert weeks_to_bitmap([1, 2, 3]) == 0b111
    assert weeks_to_bitmap([]) == 0
    assert compress_weeks([1, 2, 3, 5, 6, 9]) == "1-3, 5-6, 9"
    assert compress_weeks([1, 3, 5]) == "1, 3, 5"
    assert compress_weeks([]) == ""


async def test_weeks_api_response_shape(client: AsyncClient):
    """API：POST /schedule 的 weeks 为 list，parsed_weeks/weeks_bitmap 同步，过滤可用。"""
    c = await client.post("/api/courses", json={"name": "普通物理"})
    course_id = c.json()["data"]["id"]
    resp = await client.post(
        "/api/schedule",
        json={"course_id": course_id, "weekday": 2, "period": 1, "weeks": "1-5, 8"},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["weeks"] == [1, 2, 3, 4, 5, 8]
    assert data["parsed_weeks"] == [1, 2, 3, 4, 5, 8]
    assert data["weeks_bitmap"] == weeks_to_bitmap([1, 2, 3, 4, 5, 8])
    assert len((await client.get("/api/schedule?week=8")).json()["data"]) == 1
    assert len((await client.get("/api/schedule?week=6")).json()["data"]) == 0


# ---------------------------------------------------------------------------
# v3.3 §3.9.2 / T1-04：ICS 课表导入（完全虚构的合成文件）
# ---------------------------------------------------------------------------

FIXTURE_ICS = Path(__file__).resolve().parent / "fixtures" / "daxueshang.ics"

_EXPECTED_COURSES = {
    "样例课程01",
    "样例课程02",
    "样例课程03",
    "样例课程04",
    "样例课程05",
    "样例课程06",
    "样例课程07",
    "样例课程08",
    "样例课程09",
    "样例课程10",
    "样例课程11",
}


async def test_import_ics_real_file(test_db):
    """合成 ICS 导入：11 门课；单双周与断档换算正确（含 3 条指定断言）。"""
    assert FIXTURE_ICS.exists(), f"缺少样本 ICS：{FIXTURE_ICS}"
    async with test_db() as session:
        svc = ScheduleService(session)
        result = await svc.import_ics(
            str(FIXTURE_ICS), semester="2000测试学期", semester_start=date(2000, 1, 3)
        )
        assert result.courses_count == 11
        assert set(result.courses) == _EXPECTED_COURSES
        assert result.entries_count > 0

        courses = {c.name: c for c in await CourseService(session).list_courses()}

        async def weeks_of(name: str, weekday: int, period: int) -> list[int]:
            entries = await svc.list_entries(course_id=courses[name].id, weekday=weekday)
            match = [e for e in entries if e.period == period]
            assert match, f"{name} 周{weekday} 第{period}节 未导入"
            return match[0].weeks

        # 样例课程08周四 1-2 节（period=1）→ 单周 1-19
        assert await weeks_of("样例课程08", 4, 1) == [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]
        # 样例课程07周三 1-2 节（period=1）→ 双周 8-12
        assert await weeks_of("样例课程07", 3, 1) == [8, 10, 12]
        # 样例课程06 周三 3-4 节（period=2）→ 1-5, 7-9（不是单周）
        assert await weeks_of("样例课程06", 3, 2) == [1, 2, 3, 4, 5, 7, 8, 9]

        # 位图与 weeks 一致
        phys = await svc.list_entries(course_id=courses["样例课程06"].id, weekday=3)
        p2 = next(x for x in phys if x.period == 2)
        assert p2.weeks_bitmap == weeks_to_bitmap([1, 2, 3, 4, 5, 7, 8, 9])

        # merge 幂等：再次导入 → 全部跳过、不新增
        again = await svc.import_ics(
            str(FIXTURE_ICS), semester="2000测试学期", semester_start=date(2000, 1, 3)
        )
        assert again.entries_count == 0
        assert len(again.skipped) == result.entries_count


async def test_import_ics_api(client: AsyncClient):
    """/api/schedule/import 上传 .ics → 返回导入结果，且导入后可按星期查询。"""
    assert FIXTURE_ICS.exists()
    with open(FIXTURE_ICS, "rb") as fh:
        content = fh.read()
    resp = await client.post(
        "/api/schedule/import",
        files={"file": ("daxueshang.ics", io.BytesIO(content), "text/calendar")},
        data={"semester": "2000测试学期", "semester_start": "2000-01-03", "mode": "merge"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["code"] == 0
    assert body["data"]["courses_count"] == 11
    assert body["data"]["entries_count"] > 0
    assert "11 门课程" in body["message"]

    resp2 = await client.get("/api/schedule?weekday=4")
    assert resp2.status_code == 200
    assert len(resp2.json()["data"]) >= 1


async def test_import_ics_replace_mode(test_db):
    """replace 模式先清空该学期再导入。"""
    assert FIXTURE_ICS.exists()
    async with test_db() as session:
        svc = ScheduleService(session)
        first = await svc.import_ics(str(FIXTURE_ICS), semester="2000测试学期",
                                     semester_start=date(2000, 1, 3))
        second = await svc.import_ics(str(FIXTURE_ICS), semester="2000测试学期",
                                      semester_start=date(2000, 1, 3), mode="replace")
        assert second.courses_count == 11
        assert second.entries_count == first.entries_count
        assert second.skipped == []


# ---------------------------------------------------------------------------
# 根因修复：请求模型 extra='forbid' → 未知字段立即 422（不再静默丢弃）
# ---------------------------------------------------------------------------


async def test_unknown_request_field_rejected_422(client: AsyncClient):
    """请求体带后端不认识的字段 → 422，而不是被静默忽略后回 200「成功」。"""
    c = await client.post("/api/courses", json={"name": "电工电子"})
    cid = c.json()["data"]["id"]

    # 1) 拼错字段名（真实字段是 auto_record）
    resp = await client.put(f"/api/courses/{cid}", json={"auto_reocrd": True})
    assert resp.status_code == 422
    assert resp.json()["code"] == int(ErrorCode.VALIDATION_ERROR)

    # 2) 正确字段仍正常
    ok = await client.put(f"/api/courses/{cid}", json={"auto_record": True})
    assert ok.status_code == 200
    assert ok.json()["data"]["auto_record"] is True

    # 3) 课表创建带未知字段 → 422
    resp = await client.post(
        "/api/schedule",
        json={"course_id": cid, "weekday": 1, "period": 1, "weeks": "1-16", "foo": 1},
    )
    assert resp.status_code == 422

    # 4) 合法课表创建仍 200
    resp = await client.post(
        "/api/schedule",
        json={"course_id": cid, "weekday": 1, "period": 1, "weeks": "1-16"},
    )
    assert resp.status_code == 200
