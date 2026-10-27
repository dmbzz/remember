"""ObsidianNoteStore 适配器（本地模式权威存储 · 架构设计 §3.5.2）。

职责：
- 正文物理落盘：`课堂笔记/<课程>/<主题>_YYYY-MM-DD.md`
- 自动计算 `content_hash`（sha256）
- 维护数据库中 Note 元数据与 SyncState
- 登记 `课堂笔记/00-任务规划/已处理文件清单.md`
"""

from __future__ import annotations

import hashlib
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import AppConfig, get_app_config
from app.core.ids import local_now
from app.db.models import Course, Note, SyncState
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.repositories.note_store import NoteMeta, NoteStore, NoteStoreCapabilities
from app.services.archive_service import ArchiveService
from app.services.obsidian_service import ObsidianService

__all__ = ["ObsidianNoteStore"]


class ObsidianNoteStore:
    """本地模式下的 NoteStore 适配器（以 Obsidian 目录为权威）。"""

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()
        self.obsidian_service = ObsidianService(self.config)
        self.archive_service = ArchiveService(self.config)

    @property
    def obsidian_root(self) -> Path:
        return Path(self.config.obsidian_root)

    def capabilities(self) -> NoteStoreCapabilities:
        return NoteStoreCapabilities(
            stores_body=True,
            is_authority=True,
            supports_offline_read=True,
        )

    def _calc_hash(self, content: str) -> str:
        return hashlib.sha256(content.encode("utf-8")).hexdigest()

    async def read(self, note_id: str) -> tuple[str, NoteMeta]:
        """按 note_id 读取笔记 Markdown 及元数据。"""
        async with self.database.session_scope() as session:
            stmt = select(Note).where(Note.note_id == note_id, Note.deleted == False)
            result = await session.execute(stmt)
            note = result.scalar_one_or_none()
            if not note:
                raise ApiError(ErrorCode.NOT_FOUND, f"笔记不存在或已删除：{note_id}")

            rel_path = note.obsidian_path
            if not rel_path:
                rel_path = f"课堂笔记/{note.course_id}/{note.topic}.md"

            if not self.obsidian_service.exists(rel_path):
                raise ApiError(ErrorCode.NOT_FOUND, f"Obsidian 文件不存在：{rel_path}")

            markdown = self.obsidian_service.read_text(rel_path)
            content_hash = self._calc_hash(markdown)
            meta = NoteMeta(
                note_id=note.note_id,
                rel_path=rel_path,
                content_hash=content_hash,
                updated_at=note.updated_at,
                origin=note.origin or "win",  # type: ignore
                deleted=note.deleted,
                size=len(markdown.encode("utf-8")),
            )
            return markdown, meta

    async def write(
        self,
        *,
        course_name: str,
        topic: str,
        date_str: str,
        markdown: str,
        origin: Literal["win", "cloud", "android"] = "win",
        note_id: str | None = None,
        lesson: int | None = None,
        transcript_id: str | None = None,
        mindmap: str | None = None,
        todos: list | None = None,
        pending: list | None = None,
        marker_stats: dict | None = None,
    ) -> NoteMeta:
        """写入笔记 Markdown、计算 hash、物理落盘并记录数据库。"""
        note_filename = self.archive_service.note_filename(topic, date_str)
        clean_course = course_name.replace("/", "_").replace("\\", "_").strip()
        rel_path = f"课堂笔记/{clean_course}/{note_filename}"

        # 物理落盘
        saved_path = self.obsidian_service.write_text(rel_path, markdown)
        content_hash = self._calc_hash(markdown)
        now_dt = datetime.now(timezone.utc)

        actual_note_id = note_id or uuid.uuid4().hex

        async with self.database.session_scope() as session:
            # 查找或解析 course_id
            stmt_c = select(Course).where(Course.name == course_name)
            res_c = await session.execute(stmt_c)
            course_obj = res_c.scalar_one_or_none()
            course_id = course_obj.id if course_obj else f"crs_{clean_course}"

            stmt_n = select(Note).where(Note.note_id == actual_note_id)
            res_n = await session.execute(stmt_n)
            note_obj = res_n.scalar_one_or_none()

            if not note_obj:
                # 检查同路径已有笔记（覆盖更新）
                stmt_p = select(Note).where(Note.obsidian_path == rel_path)
                res_p = await session.execute(stmt_p)
                note_obj = res_p.scalar_one_or_none()

            if note_obj:
                actual_note_id = note_obj.note_id
                note_obj.topic = topic
                note_obj.lesson = lesson if lesson is not None else note_obj.lesson
                note_obj.obsidian_path = rel_path
                note_obj.storage_key = rel_path
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
                    obsidian_path=rel_path,
                    storage_key=rel_path,
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

            # 更新/创建 SyncState
            stmt_s = select(SyncState).where(SyncState.note_id == actual_note_id)
            res_s = await session.execute(stmt_s)
            sync_state = res_s.scalar_one_or_none()
            if not sync_state:
                sync_state = SyncState(
                    note_id=actual_note_id,
                    win_hash=content_hash,
                    win_version=1,
                    last_synced_at=now_dt,
                )
                session.add(sync_state)
            else:
                sync_state.win_hash = content_hash
                sync_state.win_version = (sync_state.win_version or 0) + 1
                sync_state.last_synced_at = now_dt

        # 更新清单
        transcript_filename = self.archive_service.transcript_filename(
            course_name, lesson or 1, date_str
        )
        self.archive_service.register_processed(
            transcript_filename=transcript_filename,
            course_name=course_name,
            class_date=date_str,
            note_name=note_filename,
        )

        return NoteMeta(
            note_id=actual_note_id,
            rel_path=rel_path,
            content_hash=content_hash,
            updated_at=now_dt,
            origin=origin,
            deleted=False,
            size=len(markdown.encode("utf-8")),
        )

    async def list_meta(self, course_name: str | None = None) -> list[NoteMeta]:
        """列出笔记元数据清单。"""
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
                    rel_path=n.obsidian_path or "",
                    content_hash=n.content_hash or "",
                    updated_at=n.updated_at,
                    origin=n.origin or "win",  # type: ignore
                    deleted=n.deleted,
                )
                for n in notes
            ]

    async def delete(
        self, note_id: str, origin: Literal["win", "cloud", "android"] = "win"
    ) -> NoteMeta:
        """软删除笔记（标记 deleted=True，保留 tombstone）。"""
        now_dt = datetime.now(timezone.utc)
        async with self.database.session_scope() as session:
            stmt = select(Note).where(Note.note_id == note_id)
            res = await session.execute(stmt)
            note = res.scalar_one_or_none()
            if not note:
                raise ApiError(ErrorCode.NOT_FOUND, f"笔记不存在：{note_id}")

            note.deleted = True
            note.updated_at = now_dt
            note.origin = origin

            return NoteMeta(
                note_id=note.note_id,
                rel_path=note.obsidian_path or "",
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
        """按 note_id 持久化 Markdown 正文，返回实际 rel_path。

        优先级：显式 rel_path > DB 中 Note.obsidian_path > 暂存 ``_sync/<note_id>.md``。
        """
        if rel_path is None:
            async with self.database.session_scope() as session:
                stmt = select(Note).where(Note.note_id == note_id)
                res = await session.execute(stmt)
                note = res.scalar_one_or_none()
                if note and note.obsidian_path:
                    rel_path = note.obsidian_path
        if rel_path is None:
            rel_path = f"_sync/{note_id}.md"
        self.obsidian_service.write_text(rel_path, markdown)
        return rel_path

    async def read_stored(self, storage_key: str) -> str:
        return self.obsidian_service.read_text(storage_key)

    async def exists(self, note_id: str) -> bool:
        """判断笔记是否存在且未删除。"""
        async with self.database.session_scope() as session:
            stmt = select(Note.id).where(Note.note_id == note_id, Note.deleted == False)
            res = await session.execute(stmt)
            return res.scalar_one_or_none() is not None
