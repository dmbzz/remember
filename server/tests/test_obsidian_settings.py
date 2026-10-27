"""测试 Obsidian 路径自定义、健康度诊断、初始化与配置持久化。"""

from __future__ import annotations

from pathlib import Path

import pytest
from httpx import AsyncClient

from app.config import USER_CONFIG_FILE, AppConfig, reset_app_config, save_user_config
from app.db.base import Base
from app.deps import get_db
from app.main import create_app
from app.services.archive_service import ArchiveService
from app.services.obsidian_service import ObsidianService
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine


@pytest.fixture
async def test_db(tmp_path: Path):
    """创建临时测试数据库。"""
    db_file = tmp_path / "test_obsidian.db"
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
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.fixture(autouse=True)
def cleanup_user_config():
    """测试前后清理 user_config.yaml，防止污染后续测试。"""
    if USER_CONFIG_FILE.exists():
        USER_CONFIG_FILE.unlink()
    reset_app_config()
    yield
    if USER_CONFIG_FILE.exists():
        USER_CONFIG_FILE.unlink()
    reset_app_config()


@pytest.mark.asyncio
async def test_get_obsidian_status(client: AsyncClient):
    """测试获取当前生效的 Obsidian 库诊断状态。"""
    resp = await client.get("/api/settings/obsidian")
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert "path" in data
    assert "exists" in data
    assert "is_fully_initialized" in data


@pytest.mark.asyncio
async def test_validate_obsidian_path(client: AsyncClient, tmp_path: Path):
    """测试针对不同目录状态的路径校验。"""
    # 1. 检验不存在的路径
    non_existent = tmp_path / "does_not_exist"
    resp = await client.post(
        "/api/settings/obsidian/validate",
        json={"path": str(non_existent)},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["exists"] is False
    assert data["is_fully_initialized"] is False

    # 2. 检验已存在但未初始化的空目录
    empty_dir = tmp_path / "empty_vault"
    empty_dir.mkdir()
    resp = await client.post(
        "/api/settings/obsidian/validate",
        json={"path": str(empty_dir)},
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["exists"] is True
    assert data["is_dir"] is True
    assert data["is_writable"] is True
    assert data["has_notes_dir"] is False
    assert data["is_fully_initialized"] is False


@pytest.mark.asyncio
async def test_init_obsidian_vault(client: AsyncClient, tmp_path: Path):
    """测试一键初始化 Obsidian 目录骨架并切换配置。"""
    custom_vault = tmp_path / "MyCustomVault"

    resp = await client.post(
        "/api/settings/obsidian/init",
        json={
            "path": str(custom_vault),
            "auto_switch": True,
            "persist": False,
        },
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["status"]["is_fully_initialized"] is True
    assert data["status"]["has_notes_dir"] is True
    assert data["status"]["has_transcripts_dir"] is True
    assert data["status"]["has_tracking_file"] is True

    # 物理验证目录和文件确实被创建
    assert (custom_vault / "课堂笔记" / "转写原文").is_dir()
    tracking_file = custom_vault / "课堂笔记" / "00-任务规划" / "已处理文件清单.md"
    assert tracking_file.is_file()
    assert "# 已处理文件清单" in tracking_file.read_text(encoding="utf-8")


@pytest.mark.asyncio
async def test_put_settings_switch_obsidian_root_and_write(
    client: AsyncClient,
    tmp_path: Path,
):
    """测试通过 PUT /api/settings 动态切换 Obsidian 路径后，转写原文正确落盘至新目录。"""
    new_vault = tmp_path / "DynamicVault"

    # 切换配置
    resp = await client.put(
        "/api/settings",
        json={
            "obsidian_root": str(new_vault),
            "persist": False,
        },
    )
    assert resp.status_code == 200
    assert resp.json()["data"]["obsidian_root"] == str(new_vault)

    # 验证服务层立即感知新路径
    service = ObsidianService()
    saved = service.write_transcript(
        course_name="自动控制原理",
        lesson=1,
        date_str="2026-09-18",
        text="这是动态设置 Obsidian 路径后的转写文本",
    )
    assert str(new_vault) in str(saved)
    assert saved.is_file()
    assert "这是动态设置" in saved.read_text(encoding="utf-8")


def test_user_config_persistence(tmp_path: Path):
    """测试 save_user_config 持久化到 config.user.yaml，且能被配置系统高优先加载。"""
    fake_obsidian = str(tmp_path / "PersistedVault")
    save_user_config({"obsidian_root": fake_obsidian})

    assert USER_CONFIG_FILE.exists()

    cfg = AppConfig()
    assert cfg.obsidian_root == fake_obsidian


@pytest.mark.asyncio
async def test_obsidian_path_with_quotes_and_aliases(client: AsyncClient, tmp_path: Path):
    """测试路径带双引号（如从 Windows 资源管理器复制）及响应别名字段。"""
    target_vault = tmp_path / "QuotedVault"
    quoted_input = f'"{target_vault}"'

    # 1. 校验接口带引号输入
    val_resp = await client.post("/api/settings/obsidian/validate", json={"path": quoted_input})
    assert val_resp.status_code == 200
    v_data = val_resp.json()["data"]
    assert v_data["exists"] is False
    assert "is_directory" in v_data
    assert "writable" in v_data
    assert "skeleton_initialized" in v_data

    # 2. 初始化带引号输入
    init_resp = await client.post(
        "/api/settings/obsidian/init",
        json={"path": quoted_input, "auto_switch": True, "persist": False},
    )
    assert init_resp.status_code == 200
    i_data = init_resp.json()["data"]
    assert i_data["status"]["exists"] is True
    assert i_data["status"]["is_fully_initialized"] is True
    assert i_data["status"]["skeleton_initialized"] is True
