"""课程管理服务（架构设计 §1.2、§3.4，T1-01）。"""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Course, ScheduleEntry
from app.errors import ApiError, ErrorCode
from app.schemas.schedule import CourseCreate, CourseUpdate

__all__ = ["CourseService", "DEFAULT_COURSES"]

# 用户本学期 4 门核心课程（PRD §0 / ADR-001）
DEFAULT_COURSES = (
    {"name": "工程力学", "semester": "2026秋", "textbook_ref": "工程力学_工程静力学与材料力学_第3版"},
    {"name": "普通物理1", "semester": "2026秋", "textbook_ref": "普通物理学_第7版"},
    {"name": "线性代数", "semester": "2026秋", "textbook_ref": "线性代数及其应用_第3版"},
    {"name": "电工电子", "semester": "2026秋", "textbook_ref": "电工学_电工技术_第7版"},
)


class CourseService:
    """课程领域服务。"""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list_courses(self, semester: str | None = None) -> list[Course]:
        """获取课程列表。"""
        stmt = select(Course)
        if semester:
            stmt = stmt.where(Course.semester == semester)
        stmt = stmt.order_by(Course.created_at.asc())
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def get_course(self, course_id: str) -> Course:
        """根据 ID 获取课程，不存在则抛出 404。"""
        course = await self.session.get(Course, course_id)
        if not course:
            raise ApiError(ErrorCode.NOT_FOUND, f"课程不存在：{course_id}")
        return course

    async def get_by_name(self, name: str) -> Course | None:
        """根据名称精确查询。"""
        stmt = select(Course).where(Course.name == name)
        result = await self.session.execute(stmt)
        return result.scalars().first()

    async def create_course(self, data: CourseCreate) -> Course:
        """创建课程。如果同名课程已存在，抛出 CONFLICT 异常。"""
        existing = await self.get_by_name(data.name)
        if existing:
            raise ApiError(ErrorCode.CONFLICT, f"课程名称 '{data.name}' 已存在")

        course = Course(
            name=data.name.strip(),
            semester=data.semester.strip() if data.semester else None,
            teacher=data.teacher.strip() if data.teacher else None,
            textbook_ref=data.textbook_ref.strip() if data.textbook_ref else None,
            auto_record=data.auto_record,
        )
        self.session.add(course)
        await self.session.flush()
        return course

    async def update_course(self, course_id: str, data: CourseUpdate) -> Course:
        """更新课程信息。"""
        course = await self.get_course(course_id)
        if data.name is not None and data.name.strip() != course.name:
            dup = await self.get_by_name(data.name.strip())
            if dup and dup.id != course_id:
                raise ApiError(ErrorCode.CONFLICT, f"课程名称 '{data.name}' 已存在")
            course.name = data.name.strip()

        if data.semester is not None:
            course.semester = data.semester.strip() if data.semester else None
        if data.teacher is not None:
            course.teacher = data.teacher.strip() if data.teacher else None
        if data.textbook_ref is not None:
            course.textbook_ref = data.textbook_ref.strip() if data.textbook_ref else None
        # 课程级自动录音开关（FR-33）：显式传值时更新，未传则保持不变。
        if data.auto_record is not None:
            course.auto_record = data.auto_record

        await self.session.flush()
        return course

    async def delete_course(self, course_id: str) -> None:
        """删除课程及其级联检查。"""
        course = await self.get_course(course_id)
        # 检查是否有关联课表条目
        stmt = select(ScheduleEntry).where(ScheduleEntry.course_id == course_id)
        entries = (await self.session.execute(stmt)).scalars().all()
        for entry in entries:
            await self.session.delete(entry)

        await self.session.delete(course)
        await self.session.flush()

    async def ensure_default_courses(self) -> list[Course]:
        """初始化预置深圳机械专业 4 门核心课程。"""
        existing_list = await self.list_courses()
        existing_names = {c.name for c in existing_list}
        created = []
        for item in DEFAULT_COURSES:
            if item["name"] not in existing_names:
                course = Course(
                    name=item["name"],
                    semester=item.get("semester"),
                    textbook_ref=item.get("textbook_ref"),
                )
                self.session.add(course)
                created.append(course)
        if created:
            await self.session.flush()
        return await self.list_courses()
