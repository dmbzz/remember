"""教材路由：页面渲染、知识点导览索引与笔记教材回填（架构设计 §3.4、T3-03）。"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query

from app.config import AppConfig
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_note_store
from app.repositories.note_store import NoteStore
from app.schemas.common import ok
from app.schemas.textbook import (
    TextbookBackfillRequest,
    TextbookBackfillResponse,
    TextbookIndexEntryDTO,
    TextbookRenderRequest,
    TextbookRenderResponse,
)
from app.pipelines.backfill_pipeline import BackfillPipeline
from app.services.textbook_service import TextbookService

__all__ = ["router"]

router = APIRouter(prefix="/textbooks", tags=["textbooks"])


@router.post("/render", summary="渲染教材指定印刷页为图像")
async def render_textbook_pages(
    payload: TextbookRenderRequest,
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    """根据课程名与印刷页码，经两档换算引擎渲染为 PNG 图片。"""
    svc = TextbookService(config, database)
    image_paths = svc.render_pages(payload.course_name, payload.printed_pages)
    resp = TextbookRenderResponse(
        course_name=payload.course_name,
        rendered_images=[str(p) for p in image_paths],
    )
    return ok(resp.model_dump())


@router.post("/backfill", summary="对指定笔记执行教材回填与标记更新")
async def backfill_note(
    payload: TextbookBackfillRequest,
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
    note_store: NoteStore = Depends(get_note_store),
) -> dict:
    """自动扫描笔记中待确认要点，并在教材确有时回填 ◉教材 证据。"""
    pipeline = BackfillPipeline(config=config, database=database, note_store=note_store)
    backfilled_items, stats, updated = await pipeline.run(
        note_id=payload.note_id,
        course_name=payload.course_name,
    )
    resp = TextbookBackfillResponse(
        note_id=payload.note_id,
        backfilled_items=backfilled_items,
        marker_stats=stats,
        updated=updated,
    )
    return ok(resp.model_dump())


@router.get("/index", summary="查询教材导览与知识点例题索引")
async def query_textbook_index(
    course: str = Query(..., description="课程名称"),
    kp: str | None = Query(None, description="知识点过滤关键词"),
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    """查询教材例题、页码与考查范围条目。"""
    svc = TextbookService(config, database)
    entries = await svc.query_index(course, kp)
    return ok([e.model_dump() for e in entries])


@router.post("/index", summary="录入教材导览索引条目")
async def add_textbook_index_entry(
    payload: TextbookIndexEntryDTO,
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    """录入单条教材索引。"""
    svc = TextbookService(config, database)
    created = await svc.add_index_entry(payload)
    return ok(created.model_dump())
