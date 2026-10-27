"""笔记多端同步服务（FR-31 / ADR-006 / ADR-008）。

职责：
    - 同步清单（manifest）：返回服务端所有笔记的 hash 快照
    - 推送（push）：客户端 → 服务端，含乐观并发检测与冲突处理
    - 拉取（pull）：服务端 → 客户端，支持 hash 比对跳过无变更
    - 批注上行（annotation push）：Android → 服务端
    - 冲突裁决（conflict resolve）：用户手动三选一

核心设计原则（ADR-006）：
    - 服务端只做「写入协调者」，不做「内容权威」
    - 判定「谁新」一律用 hash 比对，不用端信息
    - 冲突策略 keep-both：绝不静默覆盖，保留两份 + NoteRevision 留档
    - 延迟但不丢数据
"""

from __future__ import annotations

import hashlib
import uuid
from datetime import datetime
from typing import Any, Literal

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.ids import new_id, utc_now
from app.db.models import Course, Note, NoteRevision, SyncState
from app.db.session import Database
from app.errors import ApiError, ErrorCode
from app.logging_setup import get_logger
from app.repositories.note_store import NoteStore

__all__ = ["SyncService"]

_log = get_logger("app.services.sync")


def _sha256(content: str) -> str:
    """计算内容的 sha256 哈希。"""
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


class SyncService:
    """笔记多端同步服务。"""

    def __init__(
        self,
        *,
        database: Database,
        note_store: NoteStore,
    ) -> None:
        self._db = database
        self._note_store = note_store

    # ------------------------------------------------------------------
    # 同步清单
    # ------------------------------------------------------------------
    async def get_manifest(
        self, *, since: datetime | None = None
    ) -> list[dict[str, Any]]:
        """返回服务端所有笔记的同步状态快照。

        若提供 since，只返回该时间之后更新过的笔记。
        """
        async with self._db.session_scope() as session:
            stmt = select(Note).where(Note.deleted == False)  # noqa: E712
            if since is not None:
                stmt = stmt.where(Note.updated_at >= since)
            stmt = stmt.order_by(Note.updated_at.desc())

            result = await session.execute(stmt)
            notes = result.scalars().all()

            items = []
            for note in notes:
                items.append({
                    "note_id": note.note_id,
                    "content_hash": note.content_hash,
                    "updated_at": note.updated_at,
                    "origin": note.origin,
                    "deleted": note.deleted,
                })
            return items

    # ------------------------------------------------------------------
    # 推送（客户端 → 服务端）
    # ------------------------------------------------------------------
    async def push(
        self,
        *,
        note_id: str,
        content_hash: str,
        markdown: str,
        origin: Literal["win", "cloud", "android"] = "win",
        base_hash: str | None = None,
    ) -> dict[str, Any]:
        """客户端推送笔记到服务端。

        Returns:
            dict with keys: note_id, status ('updated'|'conflict'|'created'),
            content_hash, conflict (bool), conflict_revision_id (if conflict)
        """
        # 验证 hash 一致性
        actual_hash = _sha256(markdown)
        if actual_hash != content_hash:
            raise ApiError(
                ErrorCode.VALIDATION_ERROR,
                f"content_hash 不匹配：声称 {content_hash}，实际 {actual_hash}",
            )
        if origin == "android":
            raise ApiError(ErrorCode.VALIDATION_ERROR, "Android 端只读正文，请使用批注接口")

        async with self._db.session_scope() as session:
            # 查找已有笔记
            stmt = select(Note).where(Note.note_id == note_id)
            result = await session.execute(stmt)
            note = result.scalar_one_or_none()

            if note is None:
                # 全新笔记 → 直接创建（不走 NoteStore.write 以避免循环依赖）
                return await self._create_new_note(
                    session, note_id=note_id, content_hash=content_hash,
                    markdown=markdown, origin=origin,
                )

            # 已有笔记 → 检测冲突
            server_hash = note.content_hash

            if server_hash == content_hash:
                # hash 一致 → 无需更新，但刷新同步状态
                await self._update_sync_state(
                    session, note_id=note_id, origin=origin,
                    content_hash=content_hash,
                )
                _log.info("sync_push_noop", note_id=note_id, reason="hash_match")
                return {
                    "note_id": note_id,
                    "status": "unchanged",
                    "content_hash": content_hash,
                    "conflict": False,
                }

            if base_hash is None or server_hash != base_hash:
                # 乐观并发检测失败 → 冲突！
                # 策略：keep-both（保留两份，绝不静默覆盖）
                return await self._handle_conflict(
                    session, note=note, new_hash=content_hash,
                    new_markdown=markdown, origin=origin,
                )

            # 无冲突 → 正常更新
            return await self._update_existing_note(
                session, note=note, content_hash=content_hash,
                markdown=markdown, origin=origin,
            )

    async def _create_new_note(
        self,
        session: AsyncSession,
        *,
        note_id: str,
        content_hash: str,
        markdown: str,
        origin: str,
    ) -> dict[str, Any]:
        """创建全新笔记记录并持久化正文。"""
        now = utc_now()
        # push 协议目前不携带课程元数据。用真实 Course 行承载未分类导入，
        # 避免空 course_id 在启用外键的 Postgres 上写入失败。
        course = (await session.execute(
            select(Course).where(Course.name == "未分类课程").limit(1)
        )).scalar_one_or_none()
        if course is None:
            course = Course(id=new_id("course"), name="未分类课程")
            session.add(course)
            await session.flush()
        note = Note(
            id=new_id("note"),
            note_id=note_id,
            course_id=course.id,
            topic=note_id,
            content_hash=content_hash,
            origin=origin,
            synced_from=origin,
            updated_at=now,
        )
        session.add(note)

        # 创建初始同步状态
        sync_state = SyncState(
            id=new_id("sync"),
            note_id=note_id,
            last_synced_at=now,
            updated_at=now,
        )
        self._set_version_hash(sync_state, origin, content_hash, version=1)
        session.add(sync_state)

        await session.flush()

        # ★ P0 修复：持久化正文到物理存储（ADR-006「绝不丢数据」）
        rel_path = await self._note_store.persist(note_id, markdown)
        # 回填 obsidian_path / storage_key
        note.obsidian_path = rel_path
        note.storage_key = rel_path
        await session.flush()

        _log.info("sync_push_created", note_id=note_id, origin=origin)
        return {
            "note_id": note_id,
            "status": "created",
            "content_hash": content_hash,
            "conflict": False,
        }

    async def _update_existing_note(
        self,
        session: AsyncSession,
        *,
        note: Note,
        content_hash: str,
        markdown: str,
        origin: str,
    ) -> dict[str, Any]:
        """无冲突更新已有笔记。"""
        # 先写正文，成功后才推进 DB 中的 hash。失败时客户端可安全重试。
        rel_path = await self._note_store.persist(
            note.note_id,
            markdown,
            rel_path=note.storage_key or note.obsidian_path,
        )
        now = utc_now()
        note.storage_key = rel_path
        if not note.obsidian_path:
            note.obsidian_path = rel_path
        note.content_hash = content_hash
        note.origin = origin
        note.synced_from = origin
        note.updated_at = now

        await self._update_sync_state(
            session, note_id=note.note_id, origin=origin,
            content_hash=content_hash,
        )

        await session.flush()

        _log.info("sync_push_updated", note_id=note.note_id, origin=origin)
        return {
            "note_id": note.note_id,
            "status": "updated",
            "content_hash": content_hash,
            "conflict": False,
        }

    async def _handle_conflict(
        self,
        session: AsyncSession,
        *,
        note: Note,
        new_hash: str,
        new_markdown: str,
        origin: str,
    ) -> dict[str, Any]:
        """处理同步冲突：keep-both 策略。

        1. 保留服务端当前版本（不覆盖）
        2. 将推送方的版本存为冲突副本（NoteRevision）
        3. 标记 SyncState.conflict = True
        4. 返回 conflict 状态，由客户端/用户裁决
        """
        now = utc_now()

        # 存冲突副本到 NoteRevision
        # 查询当前最大 rev
        rev_stmt = (
            select(NoteRevision.rev)
            .where(NoteRevision.note_id == note.note_id)
            .order_by(NoteRevision.rev.desc())
            .limit(1)
        )
        rev_result = await session.execute(rev_stmt)
        max_rev = rev_result.scalar_one_or_none() or 0

        conflict_key = f"_conflicts/{note.note_id}/{new_hash}.md"
        # 冲突副本必须先写入独立文件；不能让 revision 只保存一个空引用。
        saved_key = await self._note_store.persist(
            note.note_id, new_markdown, rel_path=conflict_key,
        )
        conflict_revision = NoteRevision(
            id=new_id("nrev"),
            note_id=note.note_id,
            rev=max_rev + 1,
            content_hash=new_hash,
            storage_key=saved_key,
            origin=origin,
            created_at=now,
        )
        session.add(conflict_revision)

        # 标记 SyncState 冲突
        sync_stmt = select(SyncState).where(SyncState.note_id == note.note_id)
        sync_result = await session.execute(sync_stmt)
        sync_state = sync_result.scalar_one_or_none()

        if sync_state is None:
            sync_state = SyncState(
                id=new_id("sync"),
                note_id=note.note_id,
                conflict=True,
                conflict_refs=[note.content_hash, new_hash],
                updated_at=now,
            )
            session.add(sync_state)
        else:
            sync_state.conflict = True
            sync_state.conflict_refs = [note.content_hash, new_hash]
            sync_state.updated_at = now

        await session.flush()

        _log.warning(
            "sync_conflict",
            note_id=note.note_id,
            server_hash=note.content_hash,
            client_hash=new_hash,
            origin=origin,
            revision_id=conflict_revision.id,
        )
        return {
            "note_id": note.note_id,
            "status": "conflict",
            "content_hash": note.content_hash,  # 服务端当前版本
            "conflict": True,
            "conflict_revision_id": conflict_revision.id,
        }

    # ------------------------------------------------------------------
    # 拉取（服务端 → 客户端）
    # ------------------------------------------------------------------
    async def pull(
        self,
        *,
        note_id: str,
        known_hash: str | None = None,
    ) -> dict[str, Any]:
        """客户端从服务端拉取笔记。

        若 known_hash 与服务端一致，返回 changed=False（304 语义）。
        """
        async with self._db.session_scope() as session:
            stmt = select(Note).where(Note.note_id == note_id)
            result = await session.execute(stmt)
            note = result.scalar_one_or_none()

            if note is None:
                raise ApiError(
                    ErrorCode.NOT_FOUND,
                    f"笔记不存在：{note_id}",
                )

            if note.deleted:
                return {
                    "note_id": note_id,
                    "content_hash": note.content_hash,
                    "markdown": None,
                    "updated_at": note.updated_at,
                    "origin": note.origin,
                    "deleted": True,
                    "changed": True,
                }

            # hash 比对 → 未变则跳过正文读取
            if known_hash is not None and note.content_hash == known_hash:
                return {
                    "note_id": note_id,
                    "content_hash": note.content_hash,
                    "markdown": None,
                    "updated_at": note.updated_at,
                    "origin": note.origin,
                    "deleted": False,
                    "changed": False,
                }

            # 读取正文
            try:
                markdown, _meta = await self._note_store.read(note_id)
            except Exception as exc:
                raise ApiError(
                    ErrorCode.NOTE_ERROR,
                    f"读取笔记正文失败：{note_id} — {exc}",
                ) from exc

            return {
                "note_id": note_id,
                "content_hash": note.content_hash,
                "markdown": markdown,
                "updated_at": note.updated_at,
                "origin": note.origin,
                "deleted": False,
                "changed": True,
            }

    # ------------------------------------------------------------------
    # 同步状态查询
    # ------------------------------------------------------------------
    async def get_sync_state(self, note_id: str) -> dict[str, Any] | None:
        """查询单篇笔记的三方同步状态。"""
        async with self._db.session_scope() as session:
            stmt = select(SyncState).where(SyncState.note_id == note_id)
            result = await session.execute(stmt)
            sync_state = result.scalar_one_or_none()
            if sync_state is None:
                return None
            return {
                "note_id": sync_state.note_id,
                "win_version": sync_state.win_version,
                "win_hash": sync_state.win_hash,
                "cloud_version": sync_state.cloud_version,
                "cloud_hash": sync_state.cloud_hash,
                "android_version": sync_state.android_version,
                "android_hash": sync_state.android_hash,
                "last_synced_at": sync_state.last_synced_at,
                "conflict": sync_state.conflict,
                "conflict_refs": sync_state.conflict_refs or [],
                "updated_at": sync_state.updated_at,
            }

    async def list_conflicts(self) -> list[dict[str, Any]]:
        """列出所有存在冲突的笔记。"""
        async with self._db.session_scope() as session:
            stmt = (
                select(SyncState, Note.topic)
                .outerjoin(Note, SyncState.note_id == Note.note_id)
                .where(SyncState.conflict == True)  # noqa: E712
                .order_by(SyncState.updated_at.desc())
            )
            result = await session.execute(stmt)
            rows = result.all()

            items = []
            for sync_state, topic in rows:
                items.append({
                    "note_id": sync_state.note_id,
                    "topic": topic or "",
                    "conflict_refs": sync_state.conflict_refs or [],
                    "updated_at": sync_state.updated_at,
                })
            return items

    # ------------------------------------------------------------------
    # 冲突裁决
    # ------------------------------------------------------------------
    async def resolve_conflict(
        self,
        *,
        note_id: str,
        resolution: Literal["keep_remote", "keep_local", "keep_both"],
    ) -> dict[str, Any]:
        """按用户选择真正保存正文后，再清除冲突标记。"""
        async with self._db.session_scope() as session:
            sync_stmt = select(SyncState).where(SyncState.note_id == note_id)
            sync_result = await session.execute(sync_stmt)
            sync_state = sync_result.scalar_one_or_none()

            if sync_state is None or not sync_state.conflict:
                raise ApiError(
                    ErrorCode.NOT_FOUND,
                    f"笔记无冲突或不存在：{note_id}",
                )

            note = (await session.execute(
                select(Note).where(Note.note_id == note_id)
            )).scalar_one_or_none()
            revision = (await session.execute(
                select(NoteRevision)
                .where(NoteRevision.note_id == note_id)
                .order_by(NoteRevision.rev.desc())
                .limit(1)
            )).scalar_one_or_none()
            if note is None or revision is None or not revision.storage_key:
                raise ApiError(ErrorCode.NOTE_ERROR, f"冲突副本缺失：{note_id}")

            new_note_id: str | None = None
            if resolution != "keep_remote":
                incoming = await self._note_store.read_stored(revision.storage_key)
                if _sha256(incoming) != revision.content_hash:
                    raise ApiError(ErrorCode.NOTE_ERROR, f"冲突副本校验失败：{note_id}")

                if resolution == "keep_both":
                    new_note_id = uuid.uuid4().hex
                    new_path = await self._note_store.persist(
                        new_note_id, incoming, rel_path=f"_sync/{new_note_id}.md",
                    )
                    session.add(Note(
                        id=new_id("note"), note_id=new_note_id,
                        course_id=note.course_id,
                        lesson=note.lesson,
                        topic=f"{note.topic[:110]}（冲突副本）",
                        obsidian_path=new_path, storage_key=new_path,
                        content_hash=revision.content_hash,
                        origin=revision.origin, synced_from=revision.origin,
                        updated_at=utc_now(),
                    ))
                    await session.flush()
                    await self._update_sync_state(
                        session, note_id=new_note_id, origin=revision.origin,
                        content_hash=revision.content_hash,
                    )
                else:  # keep_local：先备份服务端当前版本，再替换正文。
                    old_body, _ = await self._note_store.read(note_id)
                    if _sha256(old_body) != note.content_hash:
                        raise ApiError(ErrorCode.NOTE_ERROR, f"服务端正文校验失败：{note_id}")
                    old_key = await self._note_store.persist(
                        note_id, old_body,
                        rel_path=f"_conflicts/{note_id}/{note.content_hash}.md",
                    )
                    session.add(NoteRevision(
                        id=new_id("nrev"), note_id=note_id,
                        rev=revision.rev + 1, content_hash=note.content_hash,
                        storage_key=old_key, origin=note.origin, created_at=utc_now(),
                    ))
                    canonical_path = await self._note_store.persist(
                        note_id, incoming,
                        rel_path=note.storage_key or note.obsidian_path,
                    )
                    note.storage_key = canonical_path
                    if not note.obsidian_path:
                        note.obsidian_path = canonical_path
                    note.content_hash = revision.content_hash
                    note.origin = revision.origin
                    note.synced_from = revision.origin
                    note.updated_at = utc_now()
                    await self._update_sync_state(
                        session, note_id=note_id, origin=revision.origin,
                        content_hash=revision.content_hash,
                    )

            sync_state.conflict = False
            sync_state.conflict_refs = []
            sync_state.updated_at = utc_now()

            await session.flush()

            _log.info(
                "sync_conflict_resolved",
                note_id=note_id,
                resolution=resolution,
            )
            return {
                "note_id": note_id,
                "resolution": resolution,
                "resolved": True,
                "new_note_id": new_note_id,
            }

    # ------------------------------------------------------------------
    # 批注（Android → 云端 → Win 单向上行）
    # ------------------------------------------------------------------
    async def push_annotations(
        self,
        *,
        note_id: str,
        annotations: list[dict[str, Any]],
        origin: str = "android",
    ) -> dict[str, Any]:
        """接收 Android 端推送的批注。

        批注独立存储于 Note.pending 字段（作为结构化数据），
        不修改笔记 Markdown 正文。
        """
        async with self._db.session_scope() as session:
            stmt = select(Note).where(Note.note_id == note_id)
            result = await session.execute(stmt)
            note = result.scalar_one_or_none()

            if note is None:
                raise ApiError(
                    ErrorCode.NOT_FOUND,
                    f"笔记不存在：{note_id}",
                )

            # 将批注追加到 pending 中（独立存储，不改正文）
            existing = list(note.pending or [])
            for ann in annotations:
                ann["_origin"] = origin
                ann["_synced_at"] = utc_now().isoformat()
                existing.append(ann)

            note.pending = existing
            await session.flush()

            _log.info(
                "sync_annotations_pushed",
                note_id=note_id,
                count=len(annotations),
                origin=origin,
            )
            return {
                "note_id": note_id,
                "annotations_count": len(annotations),
                "total_pending": len(existing),
            }

    async def get_annotations(self, note_id: str) -> list[dict[str, Any]]:
        """获取笔记的批注列表。"""
        async with self._db.session_scope() as session:
            stmt = select(Note).where(Note.note_id == note_id)
            result = await session.execute(stmt)
            note = result.scalar_one_or_none()

            if note is None:
                raise ApiError(
                    ErrorCode.NOT_FOUND,
                    f"笔记不存在：{note_id}",
                )

            return list(note.pending or [])

    # ------------------------------------------------------------------
    # 内部辅助
    # ------------------------------------------------------------------
    async def _update_sync_state(
        self,
        session: AsyncSession,
        *,
        note_id: str,
        origin: str,
        content_hash: str,
    ) -> None:
        """更新三方同步状态。"""
        stmt = select(SyncState).where(SyncState.note_id == note_id)
        result = await session.execute(stmt)
        sync_state = result.scalar_one_or_none()

        now = utc_now()
        if sync_state is None:
            sync_state = SyncState(
                id=new_id("sync"),
                note_id=note_id,
                last_synced_at=now,
                updated_at=now,
            )
            self._set_version_hash(sync_state, origin, content_hash, version=1)
            session.add(sync_state)
        else:
            current_version = self._get_version(sync_state, origin)
            self._set_version_hash(
                sync_state, origin, content_hash,
                version=current_version + 1,
            )
            sync_state.last_synced_at = now
            sync_state.updated_at = now

    @staticmethod
    def _set_version_hash(
        state: SyncState,
        origin: str,
        content_hash: str,
        *,
        version: int,
    ) -> None:
        """设置指定端的版本号和 hash。"""
        if origin == "win":
            state.win_version = version
            state.win_hash = content_hash
        elif origin == "cloud":
            state.cloud_version = version
            state.cloud_hash = content_hash
        elif origin == "android":
            state.android_version = version
            state.android_hash = content_hash

    @staticmethod
    def _get_version(state: SyncState, origin: str) -> int:
        """获取指定端的当前版本号。"""
        if origin == "win":
            return state.win_version
        elif origin == "cloud":
            return state.cloud_version
        elif origin == "android":
            return state.android_version
        return 0
