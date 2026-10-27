"""作业搜题与解题比对路由（架构设计 §3.4、T4-02，ADR-004）。"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query

from app.config import AppConfig
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_llm_provider, get_vision_provider
from app.pipelines.homework_pipeline import HomeworkPipeline
from app.providers.base import LLMProvider, VisionProvider
from app.schemas.common import ok
from app.schemas.homework import HomeworkSolveRequest, SolutionRecordDTO
from app.services.homework_service import HomeworkService

__all__ = ["router"]

router = APIRouter(prefix="/homework", tags=["homework"])


@router.post("/solve", summary="拍照/文字搜题（双路线比对，唯一确定解，ADR-004）")
async def solve_homework(
    payload: HomeworkSolveRequest,
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
    llm: LLMProvider = Depends(get_llm_provider),
    vision: VisionProvider = Depends(get_vision_provider),
) -> dict:
    """作业搜题：老师路线优先检索，AI独立解作校验，冲突时深挖原因并给出唯一结论。"""
    pipe = HomeworkPipeline(
        config=config,
        database=database,
        llm_provider=llm,
        vision_provider=vision,
    )
    svc = HomeworkService(config=config, database=database, pipeline=pipe)
    dto = await svc.solve(payload)
    return ok(dto.model_dump())


@router.get("/{id}", summary="查询单条历史解答记录")
async def get_solution(
    id: str,
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    """获取指定题目的完整双路线推导过程与最终裁决结论。"""
    svc = HomeworkService(config=config, database=database)
    dto = await svc.get_solution(id)
    return ok(dto.model_dump())


@router.get("", summary="获取最近解答记录列表")
async def list_solutions(
    limit: int = Query(20, ge=1, le=100),
    config: AppConfig = Depends(get_config),
    database: Database = Depends(get_database_dep),
) -> dict:
    """查询最近的作业解答记录。"""
    svc = HomeworkService(config=config, database=database)
    items = await svc.list_solutions(limit=limit)
    return ok([i.model_dump() for i in items])
