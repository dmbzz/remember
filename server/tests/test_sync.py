"""同步正文的落盘回归：创建、更新和冲突都必须可读。"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
from sqlalchemy import select

from app.config import AppConfig
from app.db.models import Course, Note, NoteRevision
from app.db.session import Database
from app.errors import ApiError
from app.repositories.note_store_local import ObsidianNoteStore
from app.services.sync_service import SyncService


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


@pytest.fixture
async def sync_env(tmp_path: Path):
    vault = tmp_path / "vault"
    vault.mkdir()
    db = Database(f"sqlite+aiosqlite:///{tmp_path / 'sync.db'}")
    await db.create_all()
    store = ObsidianNoteStore(config=AppConfig(obsidian_root=str(vault)), database=db)
    yield SyncService(database=db, note_store=store), db, vault
    await db.dispose()


@pytest.mark.asyncio
async def test_push_update_and_conflict_persist_distinct_bodies(sync_env):
    service, db, vault = sync_env
    first, second, rival = "# 第一版", "# 第二版", "# 另一端修改"

    created = await service.push(note_id="n1", content_hash=digest(first), markdown=first)
    assert created["status"] == "created"
    assert (vault / "_sync" / "n1.md").read_text(encoding="utf-8") == first
    async with db.session_scope() as session:
        note = (await session.execute(select(Note))).scalar_one()
        course = (await session.execute(select(Course))).scalar_one()
        assert note.course_id == course.id

    updated = await service.push(
        note_id="n1", content_hash=digest(second), markdown=second,
        base_hash=digest(first),
    )
    assert updated["status"] == "updated"
    assert (await service.pull(note_id="n1"))["markdown"] == second

    conflict = await service.push(
        note_id="n1", content_hash=digest(rival), markdown=rival,
        base_hash=digest(first),
    )
    assert conflict["status"] == "conflict"
    assert (await service.pull(note_id="n1"))["markdown"] == second
    async with db.session_scope() as session:
        revision = (await session.execute(select(NoteRevision))).scalar_one()
        note = (await session.execute(select(Note))).scalar_one()
    assert revision.storage_key is not None
    assert (vault / revision.storage_key).read_text(encoding="utf-8") == rival
    assert note.content_hash == digest(second)


@pytest.mark.asyncio
async def test_failed_update_does_not_advance_database_hash(sync_env):
    service, db, _vault = sync_env
    first = "# 可读取"
    await service.push(note_id="n2", content_hash=digest(first), markdown=first)

    async def fail_persist(*args, **kwargs):
        raise OSError("disk full")

    service._note_store.persist = fail_persist
    with pytest.raises(OSError, match="disk full"):
        await service.push(
            note_id="n2", content_hash=digest("# 新版"),
            markdown="# 新版", base_hash=digest(first),
        )
    async with db.session_scope() as session:
        note = (await session.execute(select(Note).where(Note.note_id == "n2"))).scalar_one()
        assert note.content_hash == digest(first)


@pytest.mark.asyncio
async def test_divergent_push_without_base_keeps_both_and_android_cannot_edit(sync_env):
    service, _db, _vault = sync_env
    await service.push(note_id="n4", content_hash=digest("# 初稿"), markdown="# 初稿")
    result = await service.push(
        note_id="n4", content_hash=digest("# 新稿"), markdown="# 新稿",
    )
    assert result["status"] == "conflict"
    assert (await service.pull(note_id="n4"))["markdown"] == "# 初稿"
    with pytest.raises(ApiError, match="Android"):
        await service.push(
            note_id="n4", content_hash=digest("# 手机修改"),
            markdown="# 手机修改", origin="android",
        )


@pytest.mark.asyncio
@pytest.mark.parametrize("resolution", ["keep_remote", "keep_local", "keep_both"])
async def test_conflict_resolution_preserves_selected_bodies(sync_env, resolution):
    service, db, vault = sync_env
    original, current, incoming = "# 原版", "# 服务端新版", "# 客户端新版"
    await service.push(note_id="n3", content_hash=digest(original), markdown=original)
    await service.push(
        note_id="n3", content_hash=digest(current), markdown=current,
        base_hash=digest(original),
    )
    await service.push(
        note_id="n3", content_hash=digest(incoming), markdown=incoming,
        base_hash=digest(original),
    )

    result = await service.resolve_conflict(note_id="n3", resolution=resolution)
    assert result["resolved"] is True
    assert (await service.get_sync_state("n3"))["conflict"] is False
    assert (await service.pull(note_id="n3"))["markdown"] == (
        incoming if resolution == "keep_local" else current
    )

    if resolution == "keep_both":
        new_id = result["new_note_id"]
        assert new_id and new_id != "n3"
        assert (await service.pull(note_id=new_id))["markdown"] == incoming
    elif resolution == "keep_local":
        assert (vault / "_conflicts" / "n3" / f"{digest(current)}.md").read_text(
            encoding="utf-8"
        ) == current
    else:
        # 即使用户选择服务端版本，另一端内容仍留在版本文件中供追溯。
        async with db.session_scope() as session:
            revision = (await session.execute(select(NoteRevision))).scalar_one()
        assert (vault / revision.storage_key).read_text(encoding="utf-8") == incoming
