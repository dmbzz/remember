"""录音登记与分片上传 API 与服务测试（T2-01）。"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.db.base import Base
from app.deps import get_db
from app.main import create_app
from app.schemas.recording import RecordingCreate
from app.services.course_service import CourseService
from app.services.recording_service import RecordingService


@pytest.fixture
async def test_env(tmp_path: Path):
    """创建临时数据库与存储根目录。"""
    db_file = tmp_path / "test_recordings.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)

    storage_root = tmp_path / "_storage"
    storage_root.mkdir(parents=True, exist_ok=True)
    cfg = SimpleNamespace(resolved_storage_root=storage_root)

    yield session_factory, cfg

    await engine.dispose()


@pytest.fixture
async def client(test_env):
    """FastAPI 异步测试客户端。"""
    session_factory, _ = test_env
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
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


async def test_recording_chunk_upload_and_assembly(test_env):
    """测试录音分片上传与流式合并。"""
    session_factory, cfg = test_env
    async with session_factory() as session:
        course_svc = CourseService(session)
        rec_svc = RecordingService(session, cfg)

        # 1. 建课程
        courses = await course_svc.ensure_default_courses()
        course_id = courses[0].id

        # 2. 登记录音
        rec = await rec_svc.create_recording(
            RecordingCreate(
                course_id=course_id,
                duration_ms=5400000,
                codec="aac",
            )
        )
        assert rec.id.startswith("rec_")
        assert rec.upload_status == "pending"

        # 3. 分两片上传
        chunk0 = b"FIRST_HALF_OF_AUDIO_DATA_"
        chunk1 = b"SECOND_HALF_OF_AUDIO_DATA"

        res0 = await rec_svc.save_chunk(rec.id, 0, chunk0, total_chunks=2)
        assert res0.is_completed is False

        res1 = await rec_svc.save_chunk(rec.id, 1, chunk1, total_chunks=2)
        assert res1.is_completed is True

        # 4. 合并组装
        assembled = await rec_svc.complete_upload(rec.id)
        assert assembled.upload_status == "uploaded"
        assert assembled.size_bytes == len(chunk0) + len(chunk1)
        assert Path(assembled.file_path).is_file()
        assert Path(assembled.file_path).read_bytes() == chunk0 + chunk1


async def test_recordings_api_endpoints(client: AsyncClient):
    """测试 /api/recordings 路由交互。"""
    # 1. 初始化课程
    c_resp = await client.post("/api/courses/init-defaults")
    course_id = c_resp.json()["data"][0]["id"]

    # 2. 登记录音
    create_payload = {
        "course_id": course_id,
        "duration_ms": 3600000,
        "codec": "wav",
    }
    resp = await client.post("/api/recordings", json=create_payload)
    assert resp.status_code == 200
    assert resp.json()["code"] == 0
    rec_id = resp.json()["data"]["id"]
    assert resp.json()["data"]["upload_status"] == "pending"

    # 3. 单文件直接上传
    dummy_audio = b"RIFF....WAVEfmt ....dataDUMMYAUDIOBYTES"
    files = {"file": ("audio.wav", dummy_audio, "audio/wav")}
    resp = await client.post(f"/api/recordings/{rec_id}/upload-file", files=files)
    assert resp.status_code == 200
    assert resp.json()["data"]["upload_status"] == "uploaded"
    assert resp.json()["data"]["size_bytes"] == len(dummy_audio)

    # 4. 获取详情
    resp = await client.get(f"/api/recordings/{rec_id}")
    assert resp.status_code == 200
    assert resp.json()["data"]["id"] == rec_id

    # 5. 查询列表
    resp = await client.get("/api/recordings?upload_status=uploaded")
    assert resp.status_code == 200
    assert len(resp.json()["data"]) >= 1
