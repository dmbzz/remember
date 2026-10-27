"""课程与课表相关 DTO（架构设计 §3.4、§3.1）。"""

from __future__ import annotations

from datetime import date, datetime
from typing import Any, Literal
from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "CourseCreate",
    "CourseUpdate",
    "CourseResponse",
    "ScheduleEntryCreate",
    "ScheduleEntryUpdate",
    "ScheduleMoveOccurrenceRequest",
    "ScheduleEntryResponse",
    "ScheduleOCRItem",
    "ScheduleOCRResponse",
    "ScheduleConfirmItem",
    "ScheduleConfirmRequest",
    "ScheduleImportDuplicateItem",
    "ScheduleImportResult",
    "TodayScheduleItem",
    "TodayScheduleResponse",
    "ScheduleReminderItem",
    "ScheduleReminderResponse",
    "CurriculumScheduleItem",
    "CurriculumCourseItem",
    "CurriculumProfile",
    "ProfileImportRequest",
    "PresetSummary",
    "TimeSlotItem",
    "TimeSlotTemplate",
]


class CourseCreate(StrictRequestModel):
    """创建课程入参。"""

    name: str = Field(..., min_length=1, max_length=128, description="课程名称，如 工程力学")
    semester: str | None = Field(None, max_length=64, description="学期，如 2026秋")
    teacher: str | None = Field(None, max_length=128, description="授课教师")
    textbook_ref: str | None = Field(None, max_length=256, description="教材引用标识或名称")
    auto_record: bool = Field(False, description="是否开启该课「自动录音」（课程级，FR-33）")


class CourseUpdate(StrictRequestModel):
    """更新课程入参。"""

    name: str | None = Field(None, min_length=1, max_length=128)
    semester: str | None = Field(None, max_length=64)
    teacher: str | None = Field(None, max_length=128)
    textbook_ref: str | None = Field(None, max_length=256)
    auto_record: bool | None = Field(None, description="是否开启该课「自动录音」（课程级，FR-33）")


class CourseResponse(BaseModel):
    """课程响应体。"""

    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str
    semester: str | None = None
    teacher: str | None = None
    textbook_ref: str | None = None
    auto_record: bool = False
    created_at: datetime


class ScheduleEntryCreate(StrictRequestModel):
    """创建课表条目入参。"""

    course_id: str = Field(..., description="所属课程 ID")
    weekday: int = Field(..., ge=1, le=7, description="星期几（1=周一，7=周日）")
    period: int = Field(..., ge=1, le=20, description="节次，如 1 表示第 1 大节或第 1 节")
    start_time: str | None = Field(None, pattern=r"^\d{2}:\d{2}$", description="开始时间 HH:MM")
    end_time: str | None = Field(None, pattern=r"^\d{2}:\d{2}$", description="结束时间 HH:MM")
    location: str | None = Field(None, max_length=128, description="教室地点")
    weeks: str | list[int] | None = Field(
        None,
        description="周次：可传区间串 '1-16' / '1-8,10-16'，或周次集合 [1,2,3,5]；缺省按 1-16 处理",
    )
    source: Literal["manual", "ocr", "import"] = "manual"
    confirmed: bool = True


class ScheduleEntryUpdate(StrictRequestModel):
    """更新课表条目入参。"""

    course_id: str | None = None
    weekday: int | None = Field(None, ge=1, le=7)
    period: int | None = Field(None, ge=1, le=20)
    start_time: str | None = Field(None, pattern=r"^\d{2}:\d{2}$")
    end_time: str | None = Field(None, pattern=r"^\d{2}:\d{2}$")
    location: str | None = Field(None, max_length=128)
    weeks: str | list[int] | None = Field(
        None, description="周次：区间串或集合；更新时会重算 weeks_bitmap"
    )
    confirmed: bool | None = None


class ScheduleMoveOccurrenceRequest(StrictRequestModel):
    """只移动指定日期的一次课程，不改变同一记录的其他周。"""

    semester_start: date
    source_date: date
    target_date: date


class ScheduleEntryResponse(BaseModel):
    """课表条目响应体。"""

    model_config = ConfigDict(from_attributes=True)

    id: str
    course_id: str
    course_name: str | None = None
    weekday: int
    period: int
    start_time: str | None = None
    end_time: str | None = None
    location: str | None = None
    weeks: list[int] = Field(default_factory=list, description="周次集合（升序去重，v3.3 新形态）")
    parsed_weeks: list[int] = Field(
        default_factory=list, description="解析后的有效周次列表（与 weeks 一致，兼容旧字段）"
    )
    weeks_bitmap: int = Field(0, description="周次位图（派生：bitmap & (1<<(week-1))）")
    source: str = "manual"
    confirmed: bool = True
    created_at: datetime


class ScheduleOCRItem(BaseModel):
    """OCR 提取的单条待确认课表条目。"""

    course_name: str
    teacher: str | None = None
    weekday: int = Field(..., ge=1, le=7)
    period: int = Field(1, ge=1, le=20)
    start_time: str | None = None
    end_time: str | None = None
    location: str | None = None
    weeks: str | None = "1-16"
    confidence: float | None = 1.0


class ScheduleOCRResponse(BaseModel):
    """OCR 识别结果响应体（均为 confirmed=false 的待确认条目）。

    区分三种**正常返回**的结局，避免把「没跑起来」与「没识别到」混为一谈
    （Provider 不可用 / 调用失败会直接抛 ``ApiError``，不落到本响应体）：

    - ``ok``：成功结构化出条目（``items`` 非空）。
    - ``unstructured``：取到了截图原文，但未能结构化出条目（``raw_text`` 非空、``items`` 为空）。
    - ``empty``：未从截图识别到任何内容（``raw_text`` 为空、``items`` 为空）。
    """

    items: list[ScheduleOCRItem] = Field(default_factory=list)
    raw_text: str = ""
    status: Literal["ok", "empty", "unstructured"] = "ok"
    notice: str | None = Field(None, description="人读提示：解释空结果的原因，便于前端直接展示")


class ScheduleConfirmItem(StrictRequestModel):
    """确认入库条目。"""

    course_name: str
    teacher: str | None = None
    weekday: int = Field(..., ge=1, le=7)
    period: int = Field(1, ge=1, le=20)
    start_time: str | None = None
    end_time: str | None = None
    location: str | None = None
    weeks: str | list[int] | None = None


class ScheduleConfirmRequest(StrictRequestModel):
    """批量确认待入库条目。"""

    semester: str | None = None
    entries: list[ScheduleConfirmItem] = Field(..., min_length=1)


class ScheduleImportDuplicateItem(BaseModel):
    """导入时被跳过的重复条目（同课程 / 星期 / 节次已存在）。"""

    course_name: str
    weekday: int
    period: int
    reason: str = "重复条目（同课程/星期/节次已存在）"


class ScheduleImportResult(BaseModel):
    """ICS 课表导入结果（架构设计 §3.9.2）。"""

    source: Literal["ics"] = "ics"
    semester: str | None = None
    semester_start: str | None = None
    mode: Literal["merge", "replace"] = "merge"
    courses_count: int = 0
    entries_count: int = 0
    courses: list[str] = Field(default_factory=list, description="导入涉及的课程名（去重）")
    skipped: list[ScheduleImportDuplicateItem] = Field(
        default_factory=list, description="因重复被跳过的条目"
    )


class TodayScheduleItem(BaseModel):
    """当天课程条目。"""

    entry_id: str
    course_id: str
    course_name: str
    teacher: str | None = None
    period: int
    start_time: str | None = None
    end_time: str | None = None
    location: str | None = None
    status: Literal["upcoming", "ongoing", "finished"] = "upcoming"


class TodayScheduleResponse(BaseModel):
    """当天课表响应体。"""

    date: str
    weekday: int
    week_number: int | None = None
    items: list[TodayScheduleItem] = Field(default_factory=list)


class ScheduleReminderItem(BaseModel):
    """上课提醒条目。"""

    entry_id: str
    course_id: str
    course_name: str
    teacher: str | None = None
    location: str | None = None
    start_time: str
    end_time: str | None = None
    minutes_until_start: int
    is_ongoing: bool = False
    message: str = ""


class ScheduleReminderResponse(BaseModel):
    """上课提醒响应体。"""

    current_time: str
    reminders: list[ScheduleReminderItem] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# 通用学期配置清单（Curriculum Profile）与预设体系
# ---------------------------------------------------------------------------


class TimeSlotItem(BaseModel):
    """单节作息起止时间。"""

    start: str = Field(..., pattern=r"^\d{2}:\d{2}$")
    end: str = Field(..., pattern=r"^\d{2}:\d{2}$")


class TimeSlotTemplate(BaseModel):
    """高校作息节次模板。"""

    id: str
    name: str
    description: str = ""
    slots: dict[int, TimeSlotItem] = Field(default_factory=dict)


class CurriculumScheduleItem(StrictRequestModel):
    """配置清单中的课表排课安排。"""

    weekday: int = Field(..., ge=1, le=7, description="星期几（1-7）")
    period: int = Field(..., ge=1, le=20, description="节次")
    start_time: str | None = None
    end_time: str | None = None
    location: str | None = None
    weeks: str | None = "1-16"


class CurriculumCourseItem(StrictRequestModel):
    """配置清单中的单个课程条目（含其关联的排课安排）。"""

    name: str = Field(..., min_length=1, max_length=128)
    teacher: str | None = None
    textbook_ref: str | None = None
    schedule: list[CurriculumScheduleItem] = Field(default_factory=list)


class CurriculumProfile(StrictRequestModel):
    """通用学期配置清单（一键导入导出格式，支持跨端/跨学生分享）。"""

    id: str | None = None
    name: str | None = "学期课表配置"
    description: str | None = ""
    major: str | None = None
    semester: str = "2026秋"
    semester_start: str | None = None  # "YYYY-MM-DD"
    time_slot_template: str | None = "standard_830"
    courses: list[CurriculumCourseItem] = Field(default_factory=list)


class ProfileImportRequest(StrictRequestModel):
    """清单导入请求。"""

    profile: CurriculumProfile
    mode: Literal["merge", "replace"] = Field(
        "replace",
        description="导入模式：replace（清空当前学期课表并重建）或 merge（增量合并）",
    )


class PresetSummary(BaseModel):
    """预设专业模板摘要。"""

    id: str
    name: str
    description: str = ""
    major: str = ""
    course_count: int = 0
    semester: str = ""
