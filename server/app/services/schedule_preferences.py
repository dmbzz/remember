"""Shared timetable settings and explicit, transactional manual scheduling."""
from datetime import date, datetime
from typing import Literal

from pydantic import Field, StrictInt, model_validator
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Course, ScheduleEntry, SchedulePreferencesRow
from app.errors import ApiError, ErrorCode
from app.schemas.common import StrictRequestModel
from app.schemas.schedule import ScheduleEntryCreate, ScheduleEntryUpdate
from app.services.course_service import CourseService
from app.schemas.schedule import CourseCreate
from app.services.schedule_service import ScheduleService

DEFAULT_TIMES = [('08:15','09:00'),('09:05','09:50'),('10:05','10:50'),('10:55','11:40'),('14:15','15:00'),('15:05','15:50'),('16:00','16:45'),('16:50','17:35'),('19:30','20:15'),('20:20','21:05')]

def minutes(value: str) -> int:
    try:
        parsed = datetime.strptime(value, '%H:%M')
        if parsed.strftime('%H:%M') != value:
            raise ValueError()
        return parsed.hour * 60 + parsed.minute
    except (ValueError, TypeError):
        raise ValueError('时间须为有效的24小时制 HH:MM') from None

class Slot(StrictRequestModel):
    start: str
    end: str
    @model_validator(mode='after')
    def ordered(self):
        if minutes(self.start) >= minutes(self.end):
            raise ValueError('每节课的结束时间必须晚于开始时间')
        return self

class TimetablePreferences(StrictRequestModel):
    semester_start: date = date(2026,8,31)
    semester_weeks: int = Field(30, ge=1, le=30)
    term_label: str = Field('大二上', min_length=1, max_length=16)
    first_week_odd: bool = True
    default_rule: Literal['every','odd','even'] = 'every'
    slots: list[Slot] = Field(default_factory=lambda: [Slot(start=a,end=b) for a,b in DEFAULT_TIMES], min_length=1,max_length=20)
    @model_validator(mode='after')
    def valid(self):
        if self.semester_start.weekday() != 0:
            raise ValueError('第一教学周起始日期必须是周一')
        if not self.term_label.strip():
            raise ValueError('请填写课表名称')
        for a,b in zip(self.slots,self.slots[1:]):
            if minutes(b.start) < minutes(a.end):
                raise ValueError('节次须按时间先后排列，不能重叠')
        return self

class PreferencesUpdate(StrictRequestModel):
    revision: int = Field(...,ge=0)
    settings: TimetablePreferences
    apply_to_entries: bool = False

class ManualEntry(StrictRequestModel):
    revision: int = Field(...,ge=0)
    entry_id: str | None = None
    course_id: str | None = None
    course_name: str | None = Field(None,min_length=1,max_length=128)
    weekday: int = Field(...,ge=1,le=7)
    start_slot: int = Field(...,ge=1,le=20)
    end_slot: int = Field(...,ge=1,le=20)
    start_time: str | None = None
    end_time: str | None = None
    location: str = Field('',max_length=128)
    weeks: list[StrictInt] = Field(...,min_length=1,max_length=30)
    @model_validator(mode='after')
    def valid(self):
        if bool(self.course_id) == bool(self.course_name and self.course_name.strip()):
            raise ValueError('请选择课程或填写新课程名称')
        if self.end_slot < self.start_slot:
            raise ValueError('结束节次不能早于开始节次')
        if (self.start_time is None) != (self.end_time is None):
            raise ValueError('请同时设置开始与结束时间')
        if self.start_time is not None and minutes(self.end_time) <= minutes(self.start_time):
            raise ValueError('结束时间必须晚于开始时间')
        return self

async def read_preferences(session: AsyncSession) -> dict:
    row = await session.get(SchedulePreferencesRow,'default')
    settings = TimetablePreferences.model_validate(row.value) if row else TimetablePreferences()
    return {'revision': row.revision if row else 0, 'configured': row is not None,
            'settings': settings.model_dump(mode='json')}

async def save_preferences(session: AsyncSession, payload: PreferencesUpdate) -> dict:
    old = await read_preferences(session)
    if old['revision'] != payload.revision:
        raise ApiError(ErrorCode.CONFLICT,'课表设置已在另一台设备修改，请刷新后再保存')
    previous = TimetablePreferences.model_validate(old['settings'])
    changes = []
    if payload.apply_to_entries:
        entries = (await session.execute(select(ScheduleEntry))).scalars().all()
        for entry in entries:
            a = next((i for i,s in enumerate(previous.slots) if s.start == entry.start_time),None)
            b = next((i for i,s in enumerate(previous.slots) if s.end == entry.end_time),None)
            if a is None or b is None or b < a:
                continue  # custom actual times are never guessed from a legacy big-period number
            if b >= len(payload.settings.slots):
                raise ApiError(ErrorCode.CONFLICT,f'第 {b+1} 节已有排课，请先调整课程，或关闭同步调整已有课程')
            changes.append((entry,a,b))
    value=payload.settings.model_dump(mode='json')
    if old['configured']:
        result=await session.execute(update(SchedulePreferencesRow).where(
            SchedulePreferencesRow.id=='default',SchedulePreferencesRow.revision==payload.revision
        ).values(value=value,revision=payload.revision+1))
        if result.rowcount != 1:
            raise ApiError(ErrorCode.CONFLICT,'课表设置已更新，请刷新后重试')
    else:
        session.add(SchedulePreferencesRow(id='default',revision=1,value=value))
        try:
            await session.flush()
        except IntegrityError:
            await session.rollback()
            raise ApiError(ErrorCode.CONFLICT,'课表设置已更新，请刷新后重试') from None
    for entry,a,b in changes:
        entry.start_time=payload.settings.slots[a].start
        entry.end_time=payload.settings.slots[b].end
    await session.flush()
    return {'revision':payload.revision+1,'configured':True,'settings':value,'updated_entries':len(changes)}

async def save_manual(session: AsyncSession, data: ManualEntry):
    snapshot=await read_preferences(session)
    prefs=TimetablePreferences.model_validate(snapshot['settings'])
    if data.revision != snapshot['revision']:
        raise ApiError(ErrorCode.CONFLICT,'作息已在另一台设备修改，请刷新后重新选择节次')
    if data.end_slot > len(prefs.slots):
        raise ApiError(ErrorCode.VALIDATION_ERROR,'节次超出当前每天节数')
    if any(w<1 or w>prefs.semester_weeks for w in data.weeks):
        raise ApiError(ErrorCode.VALIDATION_ERROR,'所选周次超出本学期范围')
    service=ScheduleService(session)
    if data.entry_id:
        await service.get_entry(data.entry_id)  # validate before creating a course
    if data.course_id:
        course=await session.get(Course,data.course_id)
        if course is None:
            raise ApiError(ErrorCode.NOT_FOUND,'选择的课程不存在，请刷新')
    else:
        course=await CourseService(session).create_course(CourseCreate(name=data.course_name.strip()))
    fields=dict(course_id=course.id,weekday=data.weekday,period=data.start_slot,
        start_time=data.start_time or prefs.slots[data.start_slot-1].start,
        end_time=data.end_time or prefs.slots[data.end_slot-1].end,
        location=data.location,weeks=sorted(set(data.weeks)),confirmed=True)
    if data.entry_id:
        entry=await service.update_entry(data.entry_id,ScheduleEntryUpdate(**fields))
    else:
        entry=await service.create_entry(ScheduleEntryCreate(**fields))
    return service.entry_to_response(entry).model_dump()
