"""转写流水线、术语勘误、Obsidian 归档与音频删除测试（T2-02、T2-03）。"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.core.tasks import AsyncioTaskQueue
from app.db.base import Base
from app.deps import get_db, get_task_queue, get_transcription_provider
from app.main import create_app
from app.providers.base import (
    CostEstimate,
    ProviderCapabilities,
    TranscriptResult,
    TranscriptionProvider,
)
from app.schemas.recording import RecordingCreate
from app.schemas.schedule import CourseCreate
from app.services.archive_service import ArchiveService
from app.services.correction_service import CorrectionService
from app.services.course_service import CourseService
from app.services.recording_service import RecordingService
from app.services.transcription_service import TranscriptionService


class MockWhisperProvider(TranscriptionProvider):
    """模拟本地 GPU 转写 Provider。"""

    default_name = "mock_gpu"

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(name=self.name, kind="transcription", runs_offline=True)

    def estimate_cost(self, duration_sec: float) -> CostEstimate:
        return CostEstimate(provider=self.name, duration_sec=duration_sec, estimated_cost=0.0)

    async def transcribe(self, audio_path: str, options=None) -> TranscriptResult:
        # 构造包含幻觉行与典型学科音误的文本（来源于 transcript-guide.md）
        text = (
            "请不吝点赞、订阅、转发，打赏支持明镜与点点栏目\n"
            "同学们好，今天我们讲工程力学第2章。\n"
            "我们首先来看这个利息的分析，做一个耳朵，求这个耳朵的大小。\n"
            "还有在矩阵里面，如果一个右翼举针存在，那么万岁矩阵就不等于零。\n"
        )
        return TranscriptResult(
            text=text,
            provider=self.name,
            language="zh",
            duration_sec=5400.0,
        )


@pytest.fixture
async def test_env(tmp_path: Path):
    """创建测试数据库、存储目录与 Obsidian 归档目录。"""
    db_file = tmp_path / "test_transcription.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)

    storage_root = tmp_path / "_storage"
    obsidian_root = tmp_path / "Obsidian"
    storage_root.mkdir(parents=True, exist_ok=True)
    obsidian_root.mkdir(parents=True, exist_ok=True)

    cfg = SimpleNamespace(
        resolved_storage_root=storage_root,
        obsidian_root=str(obsidian_root),
        transcription_provider="mock_gpu",
    )

    queue = AsyncioTaskQueue(max_concurrency=1)
    await queue.start()

    yield session_factory, cfg, queue

    await queue.stop()
    await engine.dispose()


@pytest.fixture
async def client(test_env):
    """FastAPI 异步测试客户端。"""
    session_factory, cfg, queue = test_env
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
    app.dependency_overrides[get_task_queue] = lambda: queue
    app.dependency_overrides[get_transcription_provider] = lambda: MockWhisperProvider(config=cfg)

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


def test_correction_service_hallucination_and_terms():
    """测试术语纠偏与 Whisper 幻觉行过滤。"""
    svc = CorrectionService()
    raw = (
        "请不吝点赞、订阅、转发\n"
        "今天讨论工程力学。\n"
        "求这个耳朵对A点的矩。\n"
        "利息的分析非常重要。\n"
        "在线性代数中，右翼举针是可求逆的。\n"
    )
    cleaned = svc.filter_hallucinations(raw)
    assert "请不吝点赞" not in cleaned
    assert "今天讨论工程力学。" in cleaned

    corrected, errata = svc.apply_term_corrections(cleaned)
    assert "求这个力偶对A点的矩。" in corrected
    assert "力系的分析非常重要。" in corrected
    assert "可逆矩阵" in corrected

    errata_origs = [e["original"] for e in errata]
    assert "耳朵" in errata_origs
    assert "利息的分析" in errata_origs


async def test_transcription_full_pipeline_and_audio_deletion(test_env):
    """测试完整转写流水线：转写 -> 术语校正 -> Obsidian 归档 -> 音频安全物理删除（ADR-003）。"""
    session_factory, cfg, queue = test_env
    mock_provider = MockWhisperProvider(config=cfg)

    async with session_factory() as session:
        course_svc = CourseService(session)
        rec_svc = RecordingService(session, cfg)
        trs_svc = TranscriptionService(
            session=session,
            config=cfg,
            task_queue=queue,
            transcription_provider=mock_provider,
        )

        # 1. 创建课程与登记录音
        c = await course_svc.create_course(CourseCreate(name="工程力学"))
        rec = await rec_svc.create_recording(
            RecordingCreate(course_id=c.id, duration_ms=5400000)
        )

        # 2. 上传模拟物理音频
        dummy_audio = b"FAKE_RECORDED_AUDIO_STREAM_DATA"
        await rec_svc.save_direct_file(rec.id, dummy_audio, "lecture.aac")
        assert Path(rec.file_path).is_file()
        orig_file_path = Path(rec.file_path)

        # 3. 执行完整转写
        trs = await trs_svc.execute_transcription(rec.id, lesson=1)

        # 验证转写结果
        assert trs.id.startswith("trs_")
        assert trs.provider == "mock_gpu"
        assert "请不吝点赞" not in trs.corrected_text
        assert "力偶" in trs.corrected_text
        assert len(trs.errata) >= 2

        # 验证 Obsidian 转写原文已归档
        archive_svc = ArchiveService(cfg)
        saved_txt = archive_svc.transcript_path("工程力学", 1, rec.started_at.strftime("%Y-%m-%d"))
        assert saved_txt.is_file()
        assert "力偶" in saved_txt.read_text(encoding="utf-8")

        # 验证已处理文件清单已登记
        tracking = archive_svc.tracking_file_path
        assert tracking.is_file()
        assert "工程力学" in tracking.read_text(encoding="utf-8")
        assert saved_txt.name in tracking.read_text(encoding="utf-8")

        # 验证 ADR-003：音频物理文件已被删除！
        assert rec.transcription_status == "success"
        assert rec.file_path is None
        assert rec.deleted_at is not None
        assert not orig_file_path.exists(), "物理音频文件应当在转写验证完成后被删除 (ADR-003 / FR-15)"


async def test_transcription_api_endpoints(client: AsyncClient):
    """测试 /api/transcriptions 路由交互。"""
    # 1. 准备课程与录音
    c_resp = await client.post("/api/courses", json={"name": "线性代数"})
    c_id = c_resp.json()["data"]["id"]

    rec_resp = await client.post("/api/recordings", json={"course_id": c_id, "duration_ms": 3000})
    rec_id = rec_resp.json()["data"]["id"]

    # 上传文件
    files = {"file": ("test.aac", b"DUMMY_AUDIO_DATA", "audio/aac")}
    await client.post(f"/api/recordings/{rec_id}/upload-file", files=files)

    # 2. 提交转写任务
    trs_resp = await client.post("/api/transcriptions", json={"recording_id": rec_id, "lesson": 1})
    assert trs_resp.status_code == 200
    assert trs_resp.json()["code"] == 0
    task_id = trs_resp.json()["data"]["task_id"]
    assert task_id.startswith("task_")

    # 3. 轮询队列任务列表
    q_resp = await client.get("/api/transcriptions")
    assert q_resp.status_code == 200
    tasks = q_resp.json()["data"]
    assert len(tasks) >= 1
