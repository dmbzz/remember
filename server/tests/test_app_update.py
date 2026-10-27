"""应用内更新与版本检测 API 测试。"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.db.base import Base
from app.deps import get_db
from app.main import create_app


@pytest.fixture
async def update_client(tmp_path: Path):
    db_file = tmp_path / "test_update.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)
    storage_root = tmp_path / "_storage"
    storage_root.mkdir(parents=True, exist_ok=True)
    cfg = SimpleNamespace(resolved_storage_root=storage_root)

    app = create_app()

    async def override_get_db():
        async with session_factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c

    await engine.dispose()


@pytest.mark.asyncio
async def test_check_app_version_has_update(update_client: AsyncClient):
    """测试客户端版本低于服务端时返回 has_update=True。"""
    res = await update_client.get("/api/app/version?current_code=1")
    assert res.status_code == 200
    data = res.json()
    assert data["code"] == 0
    assert data["data"]["version"] == "0.1.37"
    assert data["data"]["version_code"] == 38
    assert data["data"]["has_update"] is True
    assert data["data"]["download_url"] == "/api/app/download"
    assert "笔记" in data["data"]["release_notes"]


@pytest.mark.asyncio
async def test_check_app_version_already_latest(update_client: AsyncClient):
    """测试客户端已是最新版本时返回 has_update=False。"""
    res = await update_client.get("/api/app/version?current_code=38")
    assert res.status_code == 200
    data = res.json()
    assert data["code"] == 0
    assert data["data"]["has_update"] is False


@pytest.mark.asyncio
async def test_brand_surfaces_keep_protocol_identity(update_client: AsyncClient):
    """用户可见名称统一；旧客户端仍能识别服务协议身份。"""
    schema = (await update_client.get("/openapi.json")).json()
    assert schema["info"]["title"] == "remember API"
    manifest = (await update_client.get("/static/manifest.json")).json()
    assert manifest["name"] == manifest["short_name"] == "remember"
    page = await update_client.get("/")
    assert "remember" in page.text
    assert "课堂学习助手" not in page.text
    health = (await update_client.get("/api/health")).json()["data"]
    assert health["app"] == "class_notes_assistant"


@pytest.mark.asyncio
async def test_download_uses_remember_filename(update_client: AsyncClient, tmp_path: Path, monkeypatch):
    """下载名称更新，安装包存储位置仍由原接口读取。"""
    from app.api import app_update

    apk = tmp_path / "fixture.apk"
    apk.write_bytes(b"isolated remember download fixture")
    monkeypatch.setattr(app_update, "APK_PATH", apk)
    response = await update_client.get("/api/app/download")
    assert response.status_code == 200
    assert response.content == apk.read_bytes()
    assert 'filename="remember_latest.apk"' in response.headers["content-disposition"]
    version = (await update_client.get("/api/app/version")).json()["data"]
    assert version["file_size_bytes"] == apk.stat().st_size


@pytest.mark.asyncio
async def test_web_icon_paths_are_served(update_client: AsyncClient):
    manifest = (await update_client.get("/static/manifest.json")).json()
    for icon in manifest["icons"]:
        response = await update_client.get("/static/" + icon["src"].split("/")[-1])
        assert response.status_code == 200
        assert response.content.startswith(b"\x89PNG\r\n\x1a\n")
