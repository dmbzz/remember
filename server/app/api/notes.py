"""课堂笔记路由：生成、检索、正文读取与删除。"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import AppConfig
from app.db.models import Course, Note
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_db, get_llm_provider, get_note_store
from app.errors import ApiError, ErrorCode
from app.providers.base import LLMProvider
from app.repositories.note_store import NoteStore
from app.schemas.common import ok
from app.schemas.note import (
    NoteContentResponse,
    NoteDTO,
    NoteGenerateRequest,
    NoteListResponse,
)
from app.services.note_generation_service import NoteGenerationService
from app.services.vault_notes_service import VaultNotesService
from app.services.note_check_service import NoteCheckRequest, NoteCheckService
from app.services.note_file_sync_service import NoteFileSyncService
from app.services.note_choice_service import (ChoiceScope, NoteChoiceRequest, NoteChoiceApply, NoteChoiceService)
from starlette.concurrency import run_in_threadpool

__all__ = ["router"]

router = APIRouter(prefix="/notes", tags=["notes"])


@router.get("/local-manifest", summary="获取电脑 Obsidian 笔记摘要清单")
async def local_notes_manifest(config: AppConfig = Depends(get_config)) -> dict:
    if config.deployment_mode != "local":
        raise ApiError(ErrorCode.VALIDATION_ERROR, "仅本地电脑提供笔记摘要核对")
    items = await run_in_threadpool(VaultNotesService(config).manifest)
    return ok({"items": items, "total": len(items)})


@router.get("/file-sync/manifest", summary="笔记文件增量同步清单")
async def note_file_manifest(config: AppConfig = Depends(get_config)) -> dict:
    return ok(await run_in_threadpool(NoteFileSyncService(config).manifest))


@router.get("/file-sync/content", summary="读取已核对摘要的原始笔记字节")
async def note_file_content(path: str = Query(max_length=1024),
                            sha256: str = Query(pattern=r"^[a-f0-9]{64}$"),
                            vault_id: str = Query(pattern=r"^[a-f0-9]{64}$"),
                            config: AppConfig = Depends(get_config)) -> dict:
    return ok(await run_in_threadpool(NoteFileSyncService(config).content, path, sha256, vault_id))


@router.post("/local-checks", summary="核对手机 Obsidian 摘要并保存检查结果")
async def record_local_check(payload: NoteCheckRequest, config: AppConfig = Depends(get_config)) -> dict:
    report = await run_in_threadpool(NoteCheckService(config).record, payload)
    return ok(report)


@router.get("/local-checks", summary="电脑查看最近手机摘要与当前笔记差异")
async def list_local_checks(config: AppConfig = Depends(get_config)) -> dict:
    reports = await run_in_threadpool(NoteCheckService(config).reports)
    return ok({"items": reports})


@router.get("/file-sync/choices", summary="获取当前手机目录的版本选择")
async def list_note_choices(device_id: str = Query(pattern=r"^[a-f0-9]{32}$"),
                            folder_id: str = Query(pattern=r"^[a-f0-9]{64}$"),
                            vault_id: str = Query(pattern=r"^[a-f0-9]{64}$"),
                            config: AppConfig = Depends(get_config)) -> dict:
    scope = ChoiceScope(device_id=device_id, folder_id=folder_id, vault_id=vault_id)
    return ok(await run_in_threadpool(NoteChoiceService(config).list, scope))


@router.post("/file-sync/choices", summary="选择手机或电脑笔记作为同步来源")
async def choose_note_version(payload: NoteChoiceRequest, config: AppConfig = Depends(get_config)) -> dict:
    return ok(await run_in_threadpool(NoteChoiceService(config).choose, payload))


@router.post("/file-sync/choices/{ident}/apply", summary="执行或确认所选版本；不保留被替换版本")
async def apply_note_choice(ident: str, payload: NoteChoiceApply, config: AppConfig = Depends(get_config)) -> dict:
    return ok(await run_in_threadpool(NoteChoiceService(config).apply, ident, payload))


@router.post("/file-sync/choices/{ident}/reject", summary="使过期的版本选择失效")
async def reject_note_choice(ident: str, payload: ChoiceScope, config: AppConfig = Depends(get_config)) -> dict:
    return ok(await run_in_threadpool(NoteChoiceService(config).reject, ident, payload))


@router.post("/generate", summary="生成融合式单文件笔记")
async def generate_note(
    payload: NoteGenerateRequest,
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
    llm: LLMProvider = Depends(get_llm_provider),
    note_store: NoteStore = Depends(get_note_store),
) -> dict:
    """按转写文本与课次信息生成符合规范的融合式单文件笔记。"""
    svc = NoteGenerationService(
        config=config,
        database=database,
        llm_provider=llm,
        note_store=note_store,
    )
    dto, markdown, stats = await svc.generate_note(payload)
    return ok(
        {
            "note": dto.model_dump(),
            "markdown": markdown,
            "marker_stats": stats,
        }
    )


@router.get("", summary="获取笔记列表")
async def list_notes(
    course: str | None = Query(None, description="按课程名称过滤"),
    q: str | None = Query(None, description="按主题关键字过滤"),
    session: AsyncSession = Depends(get_db),
    config: AppConfig = Depends(get_config),
) -> dict:
    """查询未删除的笔记列表。"""
    if config.deployment_mode == "local":
        vault_items = VaultNotesService(config).list()
        db_items: list[NoteDTO] = []
        deleted_paths: set[str] = set()
        # 旧版 SQLite 的 notes 表没有同步字段；直接读取 Obsidian 文件，避免
        # ORM 选取不存在的列让整个笔记页返回 500。
        if config.db_url.startswith("sqlite"):
            columns = {
                row[1] for row in (await session.execute(text("PRAGMA table_info(notes)"))).all()
            }
        else:
            columns = set()
        required = {"note_id", "content_hash", "origin", "deleted", "updated_at"}
        if required <= columns:
            rows = (await session.execute(select(Note, Course.name).outerjoin(
                Course, Note.course_id == Course.id
            ))).all()
            for note, course_name in rows:
                path = (note.obsidian_path or "").replace("\\", "/")
                if note.deleted:
                    deleted_paths.add(path)
                    continue
                db_items.append(NoteDTO(
                    id=note.id,
                    note_id=note.note_id,
                    course_name=course_name or note.course_id,
                    lesson=note.lesson,
                    topic=note.topic,
                    format=note.fmt,
                    obsidian_path=path,
                    content_hash=note.content_hash,
                    origin=note.origin,
                    marker_stats=note.marker_stats or {},
                    created_at=note.created_at,
                    updated_at=note.updated_at,
                ))
        by_path = {item.obsidian_path: item for item in db_items if item.obsidian_path}
        items = [
            by_path.pop(item.obsidian_path, item)
            for item in vault_items if item.obsidian_path not in deleted_paths
        ]
        items.extend(by_path.values())
        if course:
            items = [item for item in items if item.course_name == course]
        if q:
            needle = q.casefold()
            items = [item for item in items if needle in item.topic.casefold()]
        items.sort(key=lambda item: item.updated_at.timestamp(), reverse=True)
        return ok(NoteListResponse(items=items, total=len(items)).model_dump())

    stmt = (
        select(Note, Course.name)
        .outerjoin(Course, Note.course_id == Course.id)
        .where(Note.deleted == False)
        .order_by(Note.created_at.desc())
    )
    if course:
        stmt = stmt.where(Course.name == course)
    if q:
        stmt = stmt.where(Note.topic.contains(q))

    res = await session.execute(stmt)
    rows = res.all()

    items: list[dict[str, Any]] = []
    for note, course_name in rows:
        dto = NoteDTO(
            id=note.id,
            note_id=note.note_id,
            course_name=course_name or note.course_id,
            lesson=note.lesson,
            topic=note.topic,
            format=note.fmt,
            obsidian_path=note.obsidian_path,
            content_hash=note.content_hash,
            origin=note.origin,
            deleted=note.deleted,
            marker_stats=note.marker_stats or {},
            created_at=note.created_at,
            updated_at=note.updated_at,
        )
        items.append(dto.model_dump())

    return ok(NoteListResponse(items=items, total=len(items)).model_dump())


@router.get("/{id}", summary="获取单篇笔记元数据")
async def get_note_meta(
    id: str,
    session: AsyncSession = Depends(get_db),
    config: AppConfig = Depends(get_config),
) -> dict:
    """根据 id 或 note_id 获取笔记元数据。"""
    if config.deployment_mode == "local" and id.startswith("vault_"):
        dto, _ = VaultNotesService(config).find(id)
        return ok(dto.model_dump())
    stmt = (
        select(Note, Course.name)
        .outerjoin(Course, Note.course_id == Course.id)
        .where((Note.id == id) | (Note.note_id == id))
    )
    res = await session.execute(stmt)
    row = res.first()
    if not row:
        raise ApiError(ErrorCode.NOT_FOUND, f"笔记不存在：{id}")

    note, course_name = row
    dto = NoteDTO(
        id=note.id,
        note_id=note.note_id,
        course_name=course_name or note.course_id,
        lesson=note.lesson,
        topic=note.topic,
        format=note.fmt,
        obsidian_path=note.obsidian_path,
        content_hash=note.content_hash,
        origin=note.origin,
        deleted=note.deleted,
        marker_stats=note.marker_stats or {},
        created_at=note.created_at,
        updated_at=note.updated_at,
    )
    return ok(dto.model_dump())


@router.get("/{id}/content", summary="获取笔记 Markdown 全文与标记统计")
async def get_note_content(
    id: str,
    session: AsyncSession = Depends(get_db),
    note_store: NoteStore = Depends(get_note_store),
    config: AppConfig = Depends(get_config),
) -> dict:
    """读取指定笔记在本地或云端的 Markdown 正文。"""
    if config.deployment_mode == "local" and id.startswith("vault_"):
        dto, markdown = VaultNotesService(config).read(id)
        return ok(NoteContentResponse(note=dto, markdown=markdown).model_dump())
    stmt = (
        select(Note, Course.name)
        .outerjoin(Course, Note.course_id == Course.id)
        .where((Note.id == id) | (Note.note_id == id), Note.deleted == False)
    )
    res = await session.execute(stmt)
    row = res.first()
    if not row:
        raise ApiError(ErrorCode.NOT_FOUND, f"笔记不存在或已删除：{id}")

    note, course_name = row
    markdown, meta = await note_store.read(note.note_id)

    dto = NoteDTO(
        id=note.id,
        note_id=note.note_id,
        course_name=course_name or note.course_id,
        lesson=note.lesson,
        topic=note.topic,
        format=note.fmt,
        obsidian_path=note.obsidian_path,
        content_hash=meta.content_hash,
        origin=meta.origin,
        deleted=meta.deleted,
        marker_stats=note.marker_stats or {},
        created_at=note.created_at,
        updated_at=note.updated_at,
    )

    resp = NoteContentResponse(
        note=dto,
        markdown=markdown,
        marker_stats=note.marker_stats or {},
    )
    return ok(resp.model_dump())


@router.delete("/{id}", summary="软删除笔记")
async def delete_note(
    id: str,
    session: AsyncSession = Depends(get_db),
    note_store: NoteStore = Depends(get_note_store),
) -> dict:
    """软删除指定笔记（保留 tombstone）。"""
    if id.startswith("vault_"):
        raise ApiError(ErrorCode.VALIDATION_ERROR, "原有 Obsidian 笔记目前只读，不能通过应用删除")
    stmt = select(Note).where((Note.id == id) | (Note.note_id == id))
    res = await session.execute(stmt)
    note = res.scalar_one_or_none()
    if not note:
        raise ApiError(ErrorCode.NOT_FOUND, f"笔记不存在：{id}")

    meta = await note_store.delete(note.note_id)
    return ok({"note_id": meta.note_id, "deleted": meta.deleted})
