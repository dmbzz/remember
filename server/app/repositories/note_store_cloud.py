"""CloudNoteStore 适配器（云端模式权威存储 · 架构设计 §3.5.2）。

职责：
- 正文落地对象存储（`notes/<note_id>.md`）
- 维护 Postgres 中 Note 元数据与 SyncState
"""

from __future__ import annotations

import hashlib
import uuid
from datetime import datetime, timezone
from typing import Literal

from sqlalchemy import select

from app.config import AppConfig, get_app_config
from app.db.models import Course, Note, SyncState
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.providers.base import StorageProvider
from app.providers.registry import ProviderRegistry
from app.repositories.note_store import NoteMeta, NoteStoreCapabilities

__all__ = ["CloudNoteStore"]


class CloudNoteStore:
    """云端模式下的 NoteStore 适配器（以对象存储为正文权威）。"""

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
        storage_provider: StorageProvider | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()
        if storage_provider is not None:
            self.storage_provider = storage_provider
        else:
            self.storage_provider = ProviderRegistry(self.config).build_storage()

    def capabilities(self) -> NoteStoreCapabilities:
        return NoteStoreCapabilities(
            stores_body=True,
            is_authority=True,
            supports_offline_read=False,
        )

    def _calc_hash(self, content: str) -> str:
        return hashlib.sha256(content.encode("utf-8")).hexdigest()

    async def read(self, note_id: str) -> tuple[str, NoteMeta]:
        """按 note_id 读取笔记 Markdown 正文与元数据。"""
        async with self.database.session_scope() as session:
            stmt = select(Note).where(Note.note_id == note_id, Note.deleted == False)
            res = await session.execute(stmt)
            note = res.scalar_one_or_none()
            if not note:
                raise ApiError(ErrorCode.NOT_FOUND, f"云端笔记不存在：{note_id}")

            storage_key = note.storage_key or f"notes/{note_id}.md"
            raw_bytes = await self.storage_provider.get_bytes(storage_key)
            markdown = raw_bytes.decode("utf-8")
            content_hash = self._calc_hash(markdown)

            return markdown, NoteMeta(
                note_id=note.note_id,
                rel_path=note.obsidian_path or storage_key,
                content_hash=content_hash,
                updated_at=note.updated_at,
                origin=note.origin or "cloud",  # type: ignore
                deleted=note.deleted,
                size=len(raw_bytes),
            )

    async def write(
        self,
        *,
        course_name: str,
        topic: str,
        date_str: str,
        markdown: str,
        origin: Literal["win", "cloud", "android"] = "cloud",
        note_id: str | None = None,
        lesson: int | None = None,
        transcript_id: str | None = None,
        mindmap: str | None = None,
        todos: list | None = None,
        pending: list | None = None,
        marker_stats: dict | None = None,
    ) -> NoteMeta:
        """写入笔记至对象存储并更新数据库。"""
        actual_note_id = note_id or uuid.uuid4().hex
        storage_key = f"notes/{actual_note_id}.md"
        data_bytes = markdown.encode("utf-8")
        content_hash = self._calc_hash(markdown)
        now_dt = datetime.now(timezone.utc)

        await self.storage_provider.put_bytes(data_bytes, storage_key)

        clean_course = course_name.replace("/", "_").replace("\\", "_").strip()
        logical_rel_path = f"课堂笔记/{clean_course}/{topic}_{date_str}.md"

        async with self.database.session_scope() as session:
            stmt_c = select(Course).where(Course.name == course_name)
            res_c = await session.execute(stmt_c)
            course_obj = res_c.scalar_one_or_none()
            course_id = course_obj.id if course_obj else f"crs_{clean_course}"

            stmt_n = select(Note).where(Note.note_id == actual_note_id)
            res_n = await session.execute(stmt_n)
            note_obj = res_n.scalar_one_or_none()

            if note_obj:
                note_obj.topic = topic
                note_obj.lesson = lesson if lesson is not None else note_obj.lesson
                note_obj.obsidian_path = logical_rel_path
                note_obj.storage_key = storage_key
                note_obj.content_hash = content_hash
                note_obj.origin = origin
                note_obj.deleted = False
                note_obj.updated_at = now_dt
                if mindmap:
                    note_obj.mindmap = mindmap
                if todos is not None:
                    note_obj.todos = todos
                if pending is not None:
                    note_obj.pending = pending
                if marker_stats is not None:
                    note_obj.marker_stats = marker_stats
            else:
                note_obj = Note(
                    note_id=actual_note_id,
                    course_id=course_id,
                    transcript_id=transcript_id,
                    lesson=lesson,
                    topic=topic,
                    obsidian_path=logical_rel_path,
                    storage_key=storage_key,
                    content_hash=content_hash,
                    origin=origin,
                    deleted=False,
                    local_available=False,
                    mindmap=mindmap,
                    todos=todos or [],
                    pending=pending or [],
                    marker_stats=marker_stats or {},
                    created_at=now_dt,
                    updated_at=now_dt,
                )
                session.add(note_obj)

            stmt_s = select(SyncState).where(SyncState.note_id == actual_note_id)
            res_s = await session.execute(stmt_s)
            sync_state = res_s.scalar_one_or_none()
            if not sync_state:
                sync_state = SyncState(
                    note_id=actual_note_id,
                    cloud_hash=content_hash,
                    cloud_version=1,
                    last_synced_at=now_dt,
                )
                session.add(sync_state)
            else:
                sync_state.cloud_hash = content_hash
                sync_state.cloud_version = (sync_state.cloud_version or 0) + 1
                sync_state.last_synced_at = now_dt

        return NoteMeta(
            note_id=actual_note_id,
            rel_path=logical_rel_path,
            content_hash=content_hash,
            updated_at=now_dt,
            origin=origin,
            deleted=False,
            size=len(data_bytes),
        )

    async def list_meta(self, course_name: str | None = None) -> list[NoteMeta]:
        """列出云端笔记元数据清单。"""
        async with self.database.session_scope() as session:
            stmt = select(Note).where(Note.deleted == False).order_by(Note.updated_at.desc())
            if course_name:
                stmt_c = select(Course).where(Course.name == course_name)
                res_c = await session.execute(stmt_c)
                course_obj = res_c.scalar_one_or_none()
                if course_obj:
                    stmt = stmt.where(Note.course_id == course_obj.id)
                else:
                    stmt = stmt.where(Note.course_id == f"crs_{course_name}")

            res = await session.execute(stmt)
            notes = res.scalars().all()
            return [
                NoteMeta(
                    note_id=n.note_id,
                    rel_path=n.obsidian_path or n.storage_key or "",
                    content_hash=n.content_hash or "",
                    updated_at=n.updated_at,
                    origin=n.origin or "cloud",  # type: ignore
                    deleted=n.deleted,
                )
                for n in notes
            ]

    async def delete(
        self, note_id: str, origin: Literal["win", "cloud", "android"] = "cloud"
    ) -> NoteMeta:
        """软删除云端笔记。"""
        now_dt = datetime.now(timezone.utc)
        async with self.database.session_scope() as session:
            stmt = select(Note).where(Note.note_id == note_id)
            res = await session.execute(stmt)
            note = res.scalar_one_or_none()
            if not note:
                raise ApiError(ErrorCode.NOT_FOUND, f"云端笔记不存在：{note_id}")

            note.deleted = True
            note.updated_at = now_dt
            note.origin = origin

            return NoteMeta(
                note_id=note.note_id,
                rel_path=note.obsidian_path or note.storage_key or "",
                content_hash=note.content_hash or "",
                updated_at=now_dt,
                origin=origin,
                deleted=True,
            )

    async def persist(
        self,
        note_id: str,
        markdown: str,
        *,
        rel_path: str | None = None,
    ) -> str:
        """按 note_id 持久化 Markdown 至对象存储，返回 storage_key。"""
        storage_key = rel_path
        if storage_key is None:
            async with self.database.session_scope() as session:
                stmt = select(Note).where(Note.note_id == note_id)
                res = await session.execute(stmt)
                note = res.scalar_one_or_none()
                if note and note.storage_key:
                    storage_key = note.storage_key
        if storage_key is None:
            storage_key = f"notes/{note_id}.md"
        await self.storage_provider.put_bytes(
            markdown.encode("utf-8"), storage_key,
        )
        return storage_key

    async def read_stored(self, storage_key: str) -> str:
        raw = await self.storage_provider.get_bytes(storage_key)
        return raw.decode("utf-8")

    async def exists(self, note_id: str) -> bool:
        async with self.database.session_scope() as session:
            stmt = select(Note.id).where(Note.note_id == note_id, Note.deleted == False)
            res = await session.execute(stmt)
            return res.scalar_one_or_none() is not None
