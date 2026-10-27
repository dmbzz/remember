"""通用课程与课表配置清单服务（Profile & Presets）。

支持任意高校、任意专业的课程与课表快速导入、导出与预设模版套用。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any
import yaml
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import CONFIG_DIR
from app.core.ids import compress_weeks
from app.db.models import Course, ScheduleEntry
from app.errors import ApiError, ErrorCode
from app.schemas.schedule import (
    CurriculumCourseItem,
    CurriculumProfile,
    CurriculumScheduleItem,
    PresetSummary,
    TimeSlotItem,
    TimeSlotTemplate,
)
from app.services.schedule_service import assign_weeks

__all__ = ["ProfileService"]

PRESETS_DIR = CONFIG_DIR / "presets"


class ProfileService:
    """学期配置清单与预设管理服务。"""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.presets_dir = PRESETS_DIR

    # -----------------------------------------------------------------------
    # 作息节次时间模板
    # -----------------------------------------------------------------------
    def get_time_slot_templates(self) -> dict[str, TimeSlotTemplate]:
        """读取所有作息时间表模板。"""
        slots_file = self.presets_dir / "time_slots.yaml"
        if not slots_file.exists():
            return {}

        data = yaml.safe_load(slots_file.read_text(encoding="utf-8")) or {}
        raw_templates = data.get("templates", {})
        result: dict[str, TimeSlotTemplate] = {}

        for tid, tval in raw_templates.items():
            slots_map: dict[int, TimeSlotItem] = {}
            for period_k, slot_v in tval.get("slots", {}).items():
                try:
                    p = int(period_k)
                    slots_map[p] = TimeSlotItem(
                        start=str(slot_v["start"]), end=str(slot_v["end"])
                    )
                except (ValueError, KeyError):
                    continue
            result[tid] = TimeSlotTemplate(
                id=tid,
                name=tval.get("name", tid),
                description=tval.get("description", ""),
                slots=slots_map,
            )
        return result

    def resolve_period_time(
        self, template_id: str | None, period: int
    ) -> tuple[str | None, str | None]:
        """根据作息模板与节次，解析推荐的 (start_time, end_time)。"""
        if not template_id:
            return None, None
        templates = self.get_time_slot_templates()
        tpl = templates.get(template_id)
        if not tpl or period not in tpl.slots:
            return None, None
        slot = tpl.slots[period]
        return slot.start, slot.end

    # -----------------------------------------------------------------------
    # 预设模板（Presets）
    # -----------------------------------------------------------------------
    def list_presets(self) -> list[PresetSummary]:
        """扫描 presets 目录列出所有专业开箱模板。"""
        if not self.presets_dir.exists():
            return []

        summaries: list[PresetSummary] = []
        for file in sorted(self.presets_dir.glob("*.yaml")):
            if file.name == "time_slots.yaml":
                continue
            try:
                data = yaml.safe_load(file.read_text(encoding="utf-8")) or {}
                summaries.append(
                    PresetSummary(
                        id=data.get("id", file.stem),
                        name=data.get("name", file.stem),
                        description=data.get("description", ""),
                        major=data.get("major", ""),
                        course_count=len(data.get("courses", [])),
                        semester=data.get("semester", ""),
                    )
                )
            except Exception:
                continue
        return summaries

    def get_preset(self, preset_id: str) -> CurriculumProfile:
        """加载指定预设的完整清单。"""
        target = self.presets_dir / f"{preset_id}.yaml"
        if not target.exists():
            raise ApiError(ErrorCode.NOT_FOUND, f"预设模板不存在：{preset_id}")

        data = yaml.safe_load(target.read_text(encoding="utf-8")) or {}
        return CurriculumProfile.model_validate(data)

    async def apply_preset(
        self, preset_id: str, mode: str = "replace"
    ) -> dict[str, Any]:
        """一键套用专业预设。"""
        profile = self.get_preset(preset_id)
        return await self.import_profile(profile, mode=mode)

    # -----------------------------------------------------------------------
    # 清单导入 / 导出
    # -----------------------------------------------------------------------
    async def import_profile(
        self, profile: CurriculumProfile, mode: str = "replace"
    ) -> dict[str, Any]:
        """将学期配置清单全量/增量导入数据库。"""
        semester = profile.semester or "2026秋"

        # 若为替换模式，删除当前学期原有排课与课程
        if mode == "replace":
            # 查询该学期的所有课程
            c_stmt = select(Course).where(Course.semester == semester)
            old_courses = list((await self.session.execute(c_stmt)).scalars().all())
            for c in old_courses:
                # 级联删课表
                s_stmt = select(ScheduleEntry).where(ScheduleEntry.course_id == c.id)
                entries = list((await self.session.execute(s_stmt)).scalars().all())
                for e in entries:
                    await self.session.delete(e)
                await self.session.delete(c)
            await self.session.flush()

        created_courses = 0
        created_entries = 0

        for c_item in profile.courses:
            # 查找或创建课程
            c_stmt = select(Course).where(
                Course.name == c_item.name.strip(),
                Course.semester == semester,
            )
            course = (await self.session.execute(c_stmt)).scalars().first()
            if not course:
                course = Course(
                    name=c_item.name.strip(),
                    semester=semester,
                    teacher=c_item.teacher.strip() if c_item.teacher else None,
                    textbook_ref=c_item.textbook_ref.strip()
                    if c_item.textbook_ref
                    else None,
                )
                self.session.add(course)
                await self.session.flush()
                created_courses += 1
            else:
                if c_item.teacher:
                    course.teacher = c_item.teacher.strip()
                if c_item.textbook_ref:
                    course.textbook_ref = c_item.textbook_ref.strip()

            # 创建排课条目
            for s_item in c_item.schedule:
                # 智能推断时间（如果未手动指定则根据作息模板推断）
                start_t = s_item.start_time
                end_t = s_item.end_time
                if not start_t or not end_t:
                    auto_start, auto_end = self.resolve_period_time(
                        profile.time_slot_template, s_item.period
                    )
                    start_t = start_t or auto_start
                    end_t = end_t or auto_end

                entry = ScheduleEntry(
                    course_id=course.id,
                    weekday=s_item.weekday,
                    period=s_item.period,
                    start_time=start_t,
                    end_time=end_t,
                    location=s_item.location,
                    source="import",
                    confirmed=True,
                )
                assign_weeks(entry, s_item.weeks)
                self.session.add(entry)
                created_entries += 1

        await self.session.flush()

        return {
            "courses_count": created_courses,
            "schedule_entries_count": created_entries,
            "semester": semester,
            "mode": mode,
        }

    async def export_profile(self, semester: str | None = None) -> CurriculumProfile:
        """将当前数据库中的课程与课表导出为标准配置清单。"""
        c_stmt = (
            select(Course)
            .options(selectinload(Course.schedule_entries))
            .order_by(Course.created_at.asc())
        )
        if semester:
            c_stmt = c_stmt.where(Course.semester == semester)

        courses = list((await self.session.execute(c_stmt)).scalars().all())

        course_items: list[CurriculumCourseItem] = []
        for c in courses:
            sched_items = []
            for s in sorted(c.schedule_entries, key=lambda x: (x.weekday, x.period)):
                sched_items.append(
                    CurriculumScheduleItem(
                        weekday=s.weekday,
                        period=s.period,
                        start_time=s.start_time,
                        end_time=s.end_time,
                        location=s.location,
                        weeks=compress_weeks(s.weeks or []),
                    )
                )
            course_items.append(
                CurriculumCourseItem(
                    name=c.name,
                    teacher=c.teacher,
                    textbook_ref=c.textbook_ref,
                    schedule=sched_items,
                )
            )

        sem_name = semester or (courses[0].semester if courses else "2026秋")
        return CurriculumProfile(
            name=f"{sem_name} 课表清单",
            semester=sem_name or "2026秋",
            courses=course_items,
        )

    async def export_profile_yaml(self, semester: str | None = None) -> str:
        """导出为格式化 YAML 文本，便于直接复制或分享。"""
        profile = await self.export_profile(semester)
        data = profile.model_dump(exclude_none=True)
        return yaml.dump(data, allow_unicode=True, sort_keys=False)
