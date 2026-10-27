"""NoteStore 端口与 ObsidianNoteStore 适配器单元测试。"""

from __future__ import annotations

from pathlib import Path

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import AppConfig
from app.db.base import Base
from app.db.session import Database
from app.repositories.note_store import NoteMeta
from app.repositories.note_store_local import ObsidianNoteStore


@pytest.fixture
async def local_store(tmp_path: Path):
    """创建隔离的 Obsidian 目录与 SQLite 数据库环境。"""
    obsidian_root = tmp_path / "TestVault"
    obsidian_root.mkdir()

    db_file = tmp_path / "test_store.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    db = Database(db_url)
    config = AppConfig(obsidian_root=str(obsidian_root))
    store = ObsidianNoteStore(config=config, database=db)

    yield store, obsidian_root
    await engine.dispose()


@pytest.mark.asyncio
async def test_obsidian_note_store_write_and_read(local_store):
    store, root = local_store
    markdown = (
        "---\n"
        "note_id: test-uuid-123\n"
        "course: 自动控制原理\n"
        "format: 融合式（课堂实录 + 拓展讲解）\n"
        "---\n\n"
        "# 传递函数与劳斯判据\n\n"
        "## 概述\n本次课讲授系统稳定性判据。\n"
    )

    meta = await store.write(
        course_name="自动控制原理",
        topic="传递函数与劳斯判据",
        date_str="2026-09-18",
        markdown=markdown,
        lesson=1,
        note_id="test-uuid-123",
    )

    assert meta.note_id == "test-uuid-123"
    assert meta.rel_path == "课堂笔记/自动控制原理/传递函数与劳斯判据_2026-09-18.md"
    assert len(meta.content_hash) == 64  # sha256 长度

    # 物理验证文件落盘
    physical_file = root / "课堂笔记" / "自动控制原理" / "传递函数与劳斯判据_2026-09-18.md"
    assert physical_file.is_file()
    assert "劳斯判据" in physical_file.read_text(encoding="utf-8")

    # 验证清单登记
    tracking_file = root / "课堂笔记" / "00-任务规划" / "已处理文件清单.md"
    assert tracking_file.is_file()
    tracking_content = tracking_file.read_text(encoding="utf-8")
    assert "传递函数与劳斯判据_2026-09-18.md" in tracking_content

    # 验证读取
    read_text, read_meta = await store.read("test-uuid-123")
    assert read_text == markdown
    assert read_meta.content_hash == meta.content_hash
    assert read_meta.deleted is False


@pytest.mark.asyncio
async def test_obsidian_note_store_delete(local_store):
    store, _ = local_store
    markdown = "# 理论力学笔记"
    meta = await store.write(
        course_name="理论力学",
        topic="虚位移原理",
        date_str="2026-09-18",
        markdown=markdown,
        note_id="note-to-delete",
    )

    assert await store.exists("note-to-delete") is True

    # 软删除
    del_meta = await store.delete("note-to-delete")
    assert del_meta.deleted is True
    assert await store.exists("note-to-delete") is False
