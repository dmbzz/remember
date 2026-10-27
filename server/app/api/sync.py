"""笔记多端同步 API 路由（FR-31 / ADR-006 / ADR-008）。

端点清单（/api/sync/ 前缀）：
    GET  /manifest          同步清单（服务端所有笔记的 hash 快照）
    POST /push              客户端推送笔记正文
    POST /pull              客户端拉取笔记正文
    GET  /{note_id}/state   查询单篇笔记的同步状态
    GET  /conflicts         列出所有冲突
    POST /conflicts/resolve 用户裁决冲突
    POST /annotations/push  Android 批注上行
    GET  /{note_id}/annotations  获取批注列表
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from fastapi import APIRouter, Depends, Query

from app.config import AppConfig
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_note_store
from app.errors import ApiError, ErrorCode
from app.repositories.note_store import NoteStore
from app.schemas.common import ok
from app.schemas.sync import (
    AnnotationPushRequest,
    ConflictResolveRequest,
    SyncPullRequest,
    SyncPushRequest,
)
from app.services.sync_service import SyncService

__all__ = ["router"]

router = APIRouter(prefix="/sync", tags=["sync"])


def _get_sync_service(
    database: Database = Depends(get_database_dep),
    note_store: NoteStore = Depends(get_note_store),
) -> SyncService:
    """构造同步服务实例。"""
    return SyncService(database=database, note_store=note_store)


# ---------------------------------------------------------------------------
# 同步清单
# ---------------------------------------------------------------------------

@router.get("/manifest", summary="获取同步清单（所有笔记的 hash 快照）")
async def get_manifest(
    since: str | None = Query(
        None,
        description="ISO 8601 时间戳；只返回该时间之后更新过的笔记",
    ),
    svc: SyncService = Depends(_get_sync_service),
) -> dict:
    """返回服务端所有笔记的同步状态快照。"""
    since_dt: datetime | None = None
    if since:
        try:
            since_dt = datetime.fromisoformat(since)
        except ValueError:
            raise ApiError(
                ErrorCode.VALIDATION_ERROR,
                f"无效的时间格式：{since}（需 ISO 8601）",
            )

    items = await svc.get_manifest(since=since_dt)
    from app.core.ids import utc_now

    return ok({
        "items": items,
        "total": len(items),
        "server_time": utc_now().isoformat(),
    })


# ---------------------------------------------------------------------------
# 推送
# ---------------------------------------------------------------------------

@router.post("/push", summary="客户端推送笔记正文到服务端")
async def push_note(
    payload: SyncPushRequest,
    svc: SyncService = Depends(_get_sync_service),
) -> dict:
    """客户端向服务端推送笔记。含乐观并发检测，冲突时 keep-both。"""
    result = await svc.push(
        note_id=payload.note_id,
        content_hash=payload.content_hash,
        markdown=payload.markdown,
        origin=payload.origin,
        base_hash=payload.base_hash,
    )
    return ok(result)


# ---------------------------------------------------------------------------
# 拉取
# ---------------------------------------------------------------------------

@router.post("/pull", summary="客户端从服务端拉取笔记正文")
async def pull_note(
    payload: SyncPullRequest,
    svc: SyncService = Depends(_get_sync_service),
) -> dict:
    """客户端拉取笔记。hash 一致时返回 changed=False 避免传输正文。"""
    result = await svc.pull(
        note_id=payload.note_id,
        known_hash=payload.known_hash,
    )
    return ok(result)


# ---------------------------------------------------------------------------
# 同步状态
# ---------------------------------------------------------------------------

@router.get("/{note_id}/state", summary="查询单篇笔记的同步状态")
async def get_sync_state(
    note_id: str,
    svc: SyncService = Depends(_get_sync_service),
) -> dict:
    """返回指定笔记的三方同步状态。"""
    state = await svc.get_sync_state(note_id)
    if state is None:
        raise ApiError(ErrorCode.NOT_FOUND, f"笔记同步状态不存在：{note_id}")
    return ok(state)


# ---------------------------------------------------------------------------
# 冲突
# ---------------------------------------------------------------------------

@router.get("/conflicts", summary="列出所有冲突笔记")
async def list_conflicts(
    svc: SyncService = Depends(_get_sync_service),
) -> dict:
    """返回所有存在冲突的笔记列表。"""
    items = await svc.list_conflicts()
    return ok({"items": items, "total": len(items)})


@router.post("/conflicts/resolve", summary="裁决冲突")
async def resolve_conflict(
    payload: ConflictResolveRequest,
    svc: SyncService = Depends(_get_sync_service),
) -> dict:
    """用户手动裁决冲突：keep_remote / keep_local / keep_both。"""
    result = await svc.resolve_conflict(
        note_id=payload.note_id,
        resolution=payload.resolution,
    )
    return ok(result)


# ---------------------------------------------------------------------------
# 批注
# ---------------------------------------------------------------------------

@router.post("/annotations/push", summary="Android 批注上行")
async def push_annotations(
    payload: AnnotationPushRequest,
    svc: SyncService = Depends(_get_sync_service),
) -> dict:
    """接收 Android 端推送的批注（独立存储，不改正文）。"""
    result = await svc.push_annotations(
        note_id=payload.note_id,
        annotations=payload.annotations,
        origin=payload.origin,
    )
    return ok(result)


@router.get("/{note_id}/annotations", summary="获取笔记批注列表")
async def get_annotations(
    note_id: str,
    svc: SyncService = Depends(_get_sync_service),
) -> dict:
    """返回指定笔记的批注列表（含 Android 上行的批注）。"""
    annotations = await svc.get_annotations(note_id)
    return ok({
        "note_id": note_id,
        "annotations": annotations,
        "total": len(annotations),
    })
