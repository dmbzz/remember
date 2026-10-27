"""课表与提醒 API 路由（架构设计 §3.4，T1-01、T1-02、T1-03）。"""

from __future__ import annotations

import tempfile
from datetime import date
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, Query, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from app.deps import get_db, get_llm_provider, get_vision_provider
from app.errors import ApiError, ErrorCode
from app.logging_setup import get_logger
from app.providers.base import LLMProvider, VisionProvider
from app.schemas.common import ok
from app.schemas.schedule import (
    ScheduleConfirmRequest,
    ScheduleEntryCreate,
    ScheduleEntryUpdate,
    ScheduleMoveOccurrenceRequest,
)
from app.services.schedule_preferences import PreferencesUpdate, ManualEntry
from app.services.schedule_service import ScheduleService
from app.services.scheduler_service import SchedulerReminderService

__all__ = ["router"]

router = APIRouter(tags=["schedule"])

_log = get_logger("app.api.schedule")


def _schedule_service(
    session: AsyncSession = Depends(get_db),
) -> ScheduleService:
    try:
        vision = get_vision_provider()
    except Exception as exc:  # noqa: BLE001 - 视觉不可用时降级，但**必须留痕**（勿静默）
        _log.warning(
            "vision_provider_build_failed",
            error_type=type(exc).__name__,
            error=str(exc),
        )
        vision = None
    try:
        llm = get_llm_provider()
    except Exception as exc:  # noqa: BLE001
        _log.warning(
            "llm_provider_build_failed",
            error_type=type(exc).__name__,
            error=str(exc),
        )
        llm = None
    return ScheduleService(session, vision_provider=vision, llm_provider=llm)


@router.get("/schedule", summary="查询课表条目列表")
async def list_schedule(
    course_id: str | None = None,
    weekday: int | None = Query(None, ge=1, le=7, description="星期几（1-7）"),
    week: int | None = Query(None, ge=1, le=30, description="具体周次（如第 3 周）"),
    confirmed: bool | None = None,
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    """查询课表，支持按课程、星期、当前教学周次动态过滤。"""
    entries = await service.list_entries(
        course_id=course_id,
        weekday=weekday,
        week=week,
        confirmed=confirmed,
    )
    return ok([service.entry_to_response(e).model_dump() for e in entries])


@router.post("/schedule", summary="手动录入课表条目")
async def create_schedule_entry(
    payload: ScheduleEntryCreate,
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    """手动创建单条课表条目。"""
    entry = await service.create_entry(payload)
    return ok(service.entry_to_response(entry).model_dump(), message="录入课表条目成功")


@router.get("/schedule/today", summary="获取当天课程日程")
async def get_today_schedule(
    target_date: date | None = Query(None, description="指定查询日期（默认当天）"),
    semester_start: date | None = Query(None, description="学期开学首日周一（用于推算第几周）"),
    session: AsyncSession = Depends(get_db),
) -> dict:
    """获取当天课程日程及当前进行状态（upcoming / ongoing / finished）。"""
    service = SchedulerReminderService(session)
    if semester_start is None:
        from app.services.schedule_preferences import read_preferences
        prefs = await read_preferences(session)
        semester_start = date.fromisoformat(prefs['settings']['semester_start'])
    result = await service.get_today_schedule(
        target_date=target_date, semester_start_date=semester_start
    )
    return ok(result.model_dump())


@router.get("/schedule/reminders", summary="获取当前上课提醒")
async def get_schedule_reminders(
    lead_minutes: int = Query(15, ge=1, le=120, description="提前提醒时间窗口（分钟）"),
    semester_start: date | None = Query(None, description="学期开学首日周一"),
    session: AsyncSession = Depends(get_db),
) -> dict:
    """获取即将开始或当前正在进行的课程提醒，用于桌面端/移动端弹窗与一键开录。"""
    service = SchedulerReminderService(session)
    if semester_start is None:
        from app.services.schedule_preferences import read_preferences
        prefs = await read_preferences(session)
        semester_start = date.fromisoformat(prefs['settings']['semester_start'])
    result = await service.get_reminders(
        lead_minutes=lead_minutes, semester_start_date=semester_start
    )
    return ok(result.model_dump())


@router.post("/schedule/ocr", summary="课表截图 OCR 智能提取")
async def ocr_schedule(
    file: UploadFile = File(..., description="课表截图图片文件"),
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    """上传课表截图进行多模态 OCR 识别，返回待确认（confirmed=false）的条目列表。"""
    suffix = Path(file.filename or "image.png").suffix or ".png"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp_path = tmp.name

    try:
        result = await service.ocr_import(tmp_path)
    finally:
        Path(tmp_path).unlink(missing_ok=True)

    # 消息随结局变化：避免「识别完成」掩盖「其实没识别到」（原静默失败 bug 的观感根源）。
    if result.status == "ok":
        message = f"OCR 识别完成，共 {len(result.items)} 条待确认课表，请核对后确认入库"
    elif result.status == "unstructured":
        message = "已获取截图文字，但未能结构化出课表条目，请核对原文或改为手动录入"
    else:
        message = "未能从截图中识别到课表条目，请确认图片内容或改为手动录入"
    return ok(result.model_dump(), message=message)


@router.post("/schedule/confirm", summary="批量确认课表条目入库")
async def confirm_schedule_entries(
    payload: ScheduleConfirmRequest,
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    """将 OCR 识别或批量导入的待确认条目核实后写入正式数据库。"""
    entries = await service.confirm_entries(payload)
    return ok(
        [service.entry_to_response(e).model_dump() for e in entries],
        message=f"已成功确认入库 {len(entries)} 条课表",
    )


@router.post("/schedule/import", summary="导入 ICS 课表文件")
async def import_schedule_ics(
    file: UploadFile = File(..., description=".ics 课表文件（multipart/form-data）"),
    semester: str | None = Form(None, description="学期，如 2026秋"),
    semester_start: date | None = Form(None, description="学期首日（周一）YYYY-MM-DD"),
    mode: str = Form("merge", description="导入模式：merge（默认，跳过重复）/ replace（清空该学期重建）"),
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    """上传 ``.ics`` 课表文件，解析为课程与课表条目（架构设计 §3.9.2）。

    - 每个 VEVENT 展开 RRULE 为教学周次，按 ``(课程, 星期, 节次)`` 合并，
      周次取并集（表达单/双周与断档）；
    - ``semester_start`` 缺省用 2026-08-31。
    """
    suffix = Path(file.filename or "schedule.ics").suffix or ".ics"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name

    try:
        result = await service.import_ics(
            tmp_path,
            semester=semester,
            semester_start=semester_start,
            mode=mode,
        )
    finally:
        Path(tmp_path).unlink(missing_ok=True)

    if semester_start is not None:
        from app.services.schedule_preferences import read_preferences, save_preferences, PreferencesUpdate
        state=await read_preferences(service.session)
        settings={**state['settings'],'semester_start':semester_start.isoformat()}
        await save_preferences(service.session,PreferencesUpdate(revision=state['revision'],settings=settings))

    message = f"ICS 导入完成：{result.courses_count} 门课程、{result.entries_count} 条课表"
    if result.skipped:
        message += f"（跳过 {len(result.skipped)} 条重复）"
    return ok(result.model_dump(), message=message)


@router.get("/schedule/snapshot", summary="读取同一事务中的课表及作息")
async def read_timetable_snapshot(session: AsyncSession = Depends(get_db)) -> dict:
    from sqlalchemy import text
    # SQLite's legacy driver does not start a read transaction for SELECT.
    # Pin all three reads to the same database snapshot explicitly.
    if session.bind.dialect.name == 'sqlite':
        await session.execute(text('BEGIN'))
    elif session.bind.dialect.name == 'postgresql':
        await session.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'))
    from app.services.schedule_preferences import read_preferences
    from app.services.course_service import CourseService
    service=ScheduleService(session)
    prefs=await read_preferences(session)
    entries=await service.list_entries()
    courses=await CourseService(session).list_courses()
    from app.schemas.schedule import CourseResponse
    return ok({'preferences':prefs,'entries':[service.entry_to_response(e).model_dump() for e in entries],
               'courses':[CourseResponse.model_validate(c).model_dump() for c in courses]})


@router.get("/schedule/settings", summary="读取共享课表设置")
async def read_timetable_preferences(session: AsyncSession = Depends(get_db)) -> dict:
    from app.services.schedule_preferences import read_preferences
    return ok(await read_preferences(session))


@router.put("/schedule/settings", summary="保存共享作息与周次设置")
async def write_timetable_preferences(payload: PreferencesUpdate, session: AsyncSession = Depends(get_db)) -> dict:
    from app.services.schedule_preferences import save_preferences
    return ok(await save_preferences(session,payload))


@router.post("/schedule/manual", summary="独立新增或修改排课")
async def save_manual_timetable(payload: ManualEntry, session: AsyncSession = Depends(get_db)) -> dict:
    from app.services.schedule_preferences import save_manual
    return ok(await save_manual(session,payload),message="排课已保存")


@router.get("/schedule/{entry_id}", summary="获取单条课表条目")
async def get_schedule_entry(
    entry_id: str,
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    """根据 ID 查询单个课表条目。"""
    entry = await service.get_entry(entry_id)
    return ok(service.entry_to_response(entry).model_dump())


@router.post("/schedule/{entry_id}/reschedule", summary="调动指定日期的一节课")
async def reschedule_occurrence(
    entry_id: str,
    payload: ScheduleMoveOccurrenceRequest,
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    entry = await service.move_occurrence(entry_id, payload)
    return ok(service.entry_to_response(entry).model_dump(), message="单次调课成功")


@router.put("/schedule/{entry_id}", summary="更新课表条目")
async def update_schedule_entry(
    entry_id: str,
    payload: ScheduleEntryUpdate,
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    """更新单个课表条目。"""
    entry = await service.update_entry(entry_id, payload)
    return ok(service.entry_to_response(entry).model_dump(), message="更新课表条目成功")


@router.delete("/schedule/{entry_id}", summary="删除课表条目")
async def delete_schedule_entry(
    entry_id: str,
    service: ScheduleService = Depends(_schedule_service),
) -> dict:
    """删除课表条目。"""
    await service.delete_entry(entry_id)
    return ok(None, message="删除课表条目成功")
