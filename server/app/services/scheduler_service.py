"""上课提醒与当天课表服务（架构设计 §1.2、§3.4，T1-03）。"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Literal

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.ids import local_now, parse_weeks
from app.db.models import ScheduleEntry
from app.schemas.schedule import (
    ScheduleReminderItem,
    ScheduleReminderResponse,
    TodayScheduleItem,
    TodayScheduleResponse,
)
from app.services.schedule_service import ScheduleService

__all__ = ["SchedulerReminderService"]


class SchedulerReminderService:
    """上课提醒与日程判定服务。"""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.schedule_service = ScheduleService(session)

    @staticmethod
    def calculate_week_number(
        target_date: date, semester_start_date: date | None = None
    ) -> int | None:
        """根据开学首日推算当前是第几教学周（1 起）。

        若无开学日，返回 None（表示不过滤周次，列出所有匹配星期的课）。
        """
        if semester_start_date is None:
            return None
        diff_days = (target_date - semester_start_date).days
        if diff_days < 0:
            return 1
        return (diff_days // 7) + 1

    @staticmethod
    def _parse_time_minutes(time_str: str | None) -> int | None:
        """将 'HH:MM' 转为自 00:00 起的分钟数。"""
        if not time_str or ":" not in time_str:
            return None
        try:
            h, m = time_str.split(":", 1)
            return int(h) * 60 + int(m)
        except ValueError:
            return None

    async def get_today_schedule(
        self,
        target_date: date | None = None,
        semester_start_date: date | None = None,
    ) -> TodayScheduleResponse:
        """获取指定日期（默认当天）的所有课程安排，并计算进行状态。"""
        dt_now = local_now()
        cur_date = target_date or dt_now.date()
        weekday = cur_date.isoweekday()  # 1=周一, 7=周日
        week_num = self.calculate_week_number(cur_date, semester_start_date)
        from app.services.schedule_preferences import read_preferences
        state=await read_preferences(self.session)
        if state['configured'] and week_num is not None and not 1 <= week_num <= state['settings']['semester_weeks']:
            return TodayScheduleResponse(date=cur_date.isoformat(),weekday=weekday,week_number=week_num,items=[])


        entries = await self.schedule_service.list_entries(
            weekday=weekday,
            week=week_num,
            confirmed=True,
        )

        cur_minutes = dt_now.hour * 60 + dt_now.minute

        items: list[TodayScheduleItem] = []
        for entry in entries:
            start_min = self._parse_time_minutes(entry.start_time)
            end_min = self._parse_time_minutes(entry.end_time)

            status: Literal["upcoming", "ongoing", "finished"] = "upcoming"
            if start_min is not None and end_min is not None:
                if cur_minutes < start_min:
                    status = "upcoming"
                elif start_min <= cur_minutes <= end_min:
                    status = "ongoing"
                else:
                    status = "finished"
            elif start_min is not None:
                status = "ongoing" if cur_minutes >= start_min else "upcoming"

            course_name = entry.course.name if entry.course else "未知课程"
            teacher = entry.course.teacher if entry.course else None

            items.append(
                TodayScheduleItem(
                    entry_id=entry.id,
                    course_id=entry.course_id,
                    course_name=course_name,
                    teacher=teacher,
                    period=entry.period,
                    start_time=entry.start_time,
                    end_time=entry.end_time,
                    location=entry.location,
                    status=status,
                )
            )

        # 按开始时间或节次排序
        items.sort(key=lambda x: (x.start_time or f"{x.period:02d}:00", x.period))

        return TodayScheduleResponse(
            date=cur_date.isoformat(),
            weekday=weekday,
            week_number=week_num,
            items=items,
        )

    async def get_reminders(
        self,
        lead_minutes: int = 15,
        now_dt: datetime | None = None,
        semester_start_date: date | None = None,
    ) -> ScheduleReminderResponse:
        """判定当前是否有正在进行或即将开始（<= lead_minutes）的上课提醒。"""
        dt = now_dt or local_now()
        weekday = dt.date().isoweekday()
        week_num = self.calculate_week_number(dt.date(), semester_start_date)
        from app.services.schedule_preferences import read_preferences
        state=await read_preferences(self.session)
        if state['configured'] and week_num is not None and not 1 <= week_num <= state['settings']['semester_weeks']:
            return ScheduleReminderResponse(current_time=dt.isoformat(),reminders=[])


        entries = await self.schedule_service.list_entries(
            weekday=weekday,
            week=week_num,
            confirmed=True,
        )

        cur_minutes = dt.hour * 60 + dt.minute
        reminders: list[ScheduleReminderItem] = []

        for entry in entries:
            start_min = self._parse_time_minutes(entry.start_time)
            end_min = self._parse_time_minutes(entry.end_time)
            if start_min is None:
                continue

            course_name = entry.course.name if entry.course else "未知课程"
            teacher = entry.course.teacher if entry.course else None
            loc_str = f"（{entry.location}）" if entry.location else ""

            # 判定是否当前正在上课
            if end_min is not None and start_min <= cur_minutes <= end_min:
                msg = f"【正在上课】{course_name}{loc_str} 正在上课中，点击一键开录"
                reminders.append(
                    ScheduleReminderItem(
                        entry_id=entry.id,
                        course_id=entry.course_id,
                        course_name=course_name,
                        teacher=teacher,
                        location=entry.location,
                        start_time=entry.start_time or "",
                        end_time=entry.end_time,
                        minutes_until_start=0,
                        is_ongoing=True,
                        message=msg,
                    )
                )
            # 判定是否即将上课 (在提前量窗口内)
            elif 0 <= (start_min - cur_minutes) <= lead_minutes:
                diff = start_min - cur_minutes
                msg = f"【上课提醒】{course_name}{loc_str} 还有 {diff} 分钟上课，点击一键开录"
                reminders.append(
                    ScheduleReminderItem(
                        entry_id=entry.id,
                        course_id=entry.course_id,
                        course_name=course_name,
                        teacher=teacher,
                        location=entry.location,
                        start_time=entry.start_time or "",
                        end_time=entry.end_time,
                        minutes_until_start=diff,
                        is_ongoing=False,
                        message=msg,
                    )
                )

        return ScheduleReminderResponse(
            current_time=dt.strftime("%H:%M"),
            reminders=reminders,
        )
