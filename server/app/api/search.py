"""检索路由：全文搜索、索引一致性校验与全量重建（架构设计 §3.4、T4-01）。"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query

from app.config import AppConfig
from app.db.session import Database
from app.deps import get_config, get_database_dep
from app.schemas.common import ok
from app.schemas.search import ConsistencyReport, SearchResultItem
from app.services.index_service import IndexService

__all__ = ["router"]

router = APIRouter(tags=["search"])


@router.get("/search", summary="检索笔记与转写（供作业搜题与复习）")
async def search_notes(
    q: str = Query(..., description="检索关键词或题目内容"),
    course: str | None = Query(None, description="按课程名称过滤"),
    limit: int = Query(10, ge=1, le=50, description="最大返回数量"),
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    """按关键词检索笔记，优先呈现老师课堂讲法与重点。"""
    svc = IndexService(config=config, database=database)
    results = await svc.search(q, course_name=course, limit=limit)
    return ok([r.model_dump() for r in results])


@router.get("/index/verify", summary="验证索引一致性")
async def verify_index_consistency(
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    """检查索引表与物理 Obsidian 目录一致性。"""
    svc = IndexService(config=config, database=database)
    report = await svc.verify_consistency()
    return ok(report.model_dump())


@router.post("/index/rebuild", summary="全量重建检索索引")
async def rebuild_search_index(
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    """从本地 Obsidian 目录重新提取关键词并重建索引。"""
    svc = IndexService(config=config, database=database)
    indexed, removed = await svc.rebuild_index()
    return ok({"indexed": indexed, "removed": removed})
