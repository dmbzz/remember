"""课程管理 API 路由（架构设计 §3.4，T1-01）。"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.deps import get_db
from app.schemas.common import ok
from app.schemas.schedule import CourseCreate, CourseResponse, CourseUpdate
from app.services.course_service import CourseService

__all__ = ["router"]

router = APIRouter(tags=["courses"])


@router.get("/courses", summary="获取课程列表")
async def list_courses(
    semester: str | None = None,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """获取所有课程列表（可按学期过滤）。"""
    service = CourseService(session)
    courses = await service.list_courses(semester)
    return ok([CourseResponse.model_validate(c).model_dump() for c in courses])


@router.post("/courses", summary="新建课程")
async def create_course(
    payload: CourseCreate,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """创建新课程。"""
    service = CourseService(session)
    course = await service.create_course(payload)
    return ok(CourseResponse.model_validate(course).model_dump(), message="创建课程成功")


@router.post("/courses/init-defaults", summary="初始化预置课程")
async def init_default_courses(
    session: AsyncSession = Depends(get_db),
) -> dict:
    """快速初始化本学期 4 门核心课程（工程力学/普通物理1/线性代数/电工电子）。"""
    service = CourseService(session)
    courses = await service.ensure_default_courses()
    return ok([CourseResponse.model_validate(c).model_dump() for c in courses], message="初始化默认课程成功")


@router.get("/courses/{course_id}", summary="获取课程详情")
async def get_course(
    course_id: str,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """根据 ID 获取单门课程。"""
    service = CourseService(session)
    course = await service.get_course(course_id)
    return ok(CourseResponse.model_validate(course).model_dump())


@router.put("/courses/{course_id}", summary="更新课程")
async def update_course(
    course_id: str,
    payload: CourseUpdate,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """更新课程信息。"""
    service = CourseService(session)
    course = await service.update_course(course_id, payload)
    return ok(CourseResponse.model_validate(course).model_dump(), message="更新课程成功")


@router.delete("/courses/{course_id}", summary="删除课程")
async def delete_course(
    course_id: str,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """删除课程及其课表条目。"""
    service = CourseService(session)
    await service.delete_course(course_id)
    return ok(None, message="删除课程成功")
