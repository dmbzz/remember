"""课表服务（架构设计 §1.2、§3.4，T1-01、T1-02）。"""

from __future__ import annotations

import json
import re
from datetime import date, datetime, time, timedelta, timezone
from typing import Any
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.ids import (
    parse_weeks,
    weeks_to_bitmap,
)
from app.db.models import Course, ScheduleEntry
from app.errors import ApiError, ErrorCode, ProviderError
from app.logging_setup import get_logger
from app.providers.base import LLMMessage, LLMOptions, LLMProvider, VisionProvider
from app.schemas.schedule import (
    ScheduleConfirmRequest,
    ScheduleEntryCreate,
    ScheduleEntryResponse,
    ScheduleEntryUpdate,
    ScheduleMoveOccurrenceRequest,
    ScheduleImportDuplicateItem,
    ScheduleImportResult,
    ScheduleOCRItem,
    ScheduleOCRResponse,
)

__all__ = ["ScheduleService", "assign_weeks", "DEFAULT_WEEKS"]

_log = get_logger("app.services.schedule")

# 缺省周次：1-16（旧代码 `or "1-16"` 的等价集合）。
DEFAULT_WEEKS: tuple[int, ...] = tuple(range(1, 17))

# 源 ICS 使用 ``TZID=/Asia/Shanghai``；UNTIL 以 UTC 给出。
# 固定 +8 换算为本地墙钟，避免依赖系统 tzdata（Windows 可能缺失）。
_ICS_TZ = timezone(timedelta(hours=8))

# 默认学期首日（周一）：2026-08-31（用户本学期开学日）。
DEFAULT_SEMESTER_START = date(2026, 8, 31)


def assign_weeks(entry: ScheduleEntry, weeks_value: Any) -> None:
    """把 ``weeks``（区间串 / 整数集合 / None）归一为 ``list[int]`` 并回填派生位图。

    这是写入 ``ScheduleEntry.weeks`` 与 ``ScheduleEntry.weeks_bitmap`` 的**唯一出口**
    （架构设计 v3.3 §3.9.1：``weeks_bitmap`` 为派生列，**禁止手改**，一律由此回填）。
    空值按 ``DEFAULT_WEEKS``（1-16）处理，与原 ``or "1-16"`` 行为一致。
    """
    weeks = parse_weeks(weeks_value) or list(DEFAULT_WEEKS)
    entry.weeks = weeks
    entry.weeks_bitmap = weeks_to_bitmap(weeks)


# 敏感信息脱敏（避免把 api_key / Bearer token 带进错误消息）
_REDACT_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_\-]{6,}"),
    re.compile(r"(?i)(bearer\s+)[A-Za-z0-9_\-\.]{8,}"),
    re.compile(r"(?i)(api[_\-]?key\s*[=:]\s*)[A-Za-z0-9_\-]{6,}"),
)


def _truncate(text: str, limit: int = 240) -> str:
    """压缩空白并截断到 ``limit`` 字符（保留可读摘要，避免超长/换行污染消息）。"""
    compact = " ".join(str(text).split())
    return compact if len(compact) <= limit else compact[: limit - 1] + "…"


def _redact(text: str) -> str:
    """对 api_key / Bearer token 等敏感串脱敏。"""
    result = text
    for pattern in _REDACT_PATTERNS:
        result = pattern.sub(
            lambda m: (m.group(1) if m.groups() else "") + "***", result
        )
    return result


class ScheduleService:
    """课表领域服务。"""

    def __init__(
        self,
        session: AsyncSession,
        vision_provider: VisionProvider | None = None,
        llm_provider: LLMProvider | None = None,
    ) -> None:
        self.session = session
        self.vision = vision_provider
        self.llm = llm_provider

    async def list_entries(
        self,
        *,
        course_id: str | None = None,
        weekday: int | None = None,
        week: int | None = None,
        confirmed: bool | None = None,
    ) -> list[ScheduleEntry]:
        """获取课表条目列表，支持按课程、星期、周次和确认状态过滤。"""
        stmt = (
            select(ScheduleEntry)
            .options(selectinload(ScheduleEntry.course))
            .order_by(ScheduleEntry.weekday.asc(), ScheduleEntry.period.asc())
        )
        if course_id:
            stmt = stmt.where(ScheduleEntry.course_id == course_id)
        if weekday is not None:
            stmt = stmt.where(ScheduleEntry.weekday == weekday)
        if confirmed is not None:
            stmt = stmt.where(ScheduleEntry.confirmed == confirmed)

        # 周次过滤：用派生位图做位运算（v3.3 §3.9.1），
        # 等价于 `week in weeks`，但可走索引、免内存遍历。
        if week is not None and week >= 1:
            mask = 1 << (week - 1)
            stmt = stmt.where(ScheduleEntry.weeks_bitmap.op("&")(mask) != 0)

        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def get_entry(self, entry_id: str) -> ScheduleEntry:
        """获取单个课表条目。"""
        stmt = (
            select(ScheduleEntry)
            .options(selectinload(ScheduleEntry.course))
            .where(ScheduleEntry.id == entry_id)
        )
        result = await self.session.execute(stmt)
        entry = result.scalars().first()
        if not entry:
            raise ApiError(ErrorCode.NOT_FOUND, f"课表条目不存在：{entry_id}")
        return entry

    async def create_entry(self, data: ScheduleEntryCreate) -> ScheduleEntry:
        """创建课表条目。"""
        # 校验关联课程是否存在
        course = await self.session.get(Course, data.course_id)
        if not course:
            raise ApiError(ErrorCode.NOT_FOUND, f"关联课程不存在：{data.course_id}")

        entry = ScheduleEntry(
            course_id=data.course_id,
            weekday=data.weekday,
            period=data.period,
            start_time=data.start_time,
            end_time=data.end_time,
            location=data.location,
            source=data.source,
            confirmed=data.confirmed,
        )
        assign_weeks(entry, data.weeks)
        self.session.add(entry)
        await self.session.flush()
        # 刷新关联
        entry.course = course
        return entry

    async def update_entry(self, entry_id: str, data: ScheduleEntryUpdate) -> ScheduleEntry:
        """更新课表条目。"""
        entry = await self.get_entry(entry_id)
        if data.course_id is not None:
            course = await self.session.get(Course, data.course_id)
            if not course:
                raise ApiError(ErrorCode.NOT_FOUND, f"关联课程不存在：{data.course_id}")
            entry.course_id = data.course_id
            entry.course = course

        if data.weekday is not None:
            entry.weekday = data.weekday
        if data.period is not None:
            entry.period = data.period
        if data.start_time is not None:
            entry.start_time = data.start_time
        if data.end_time is not None:
            entry.end_time = data.end_time
        if data.location is not None:
            entry.location = data.location
        if data.weeks is not None:
            assign_weeks(entry, data.weeks)
        if data.confirmed is not None:
            entry.confirmed = data.confirmed

        await self.session.flush()
        return entry

    async def delete_entry(self, entry_id: str) -> None:
        """删除课表条目。"""
        entry = await self.get_entry(entry_id)
        await self.session.delete(entry)
        await self.session.flush()

    async def move_occurrence(
        self, entry_id: str, data: ScheduleMoveOccurrenceRequest
    ) -> ScheduleEntry:
        """把某个教学周的一次课移到实际日期，保留其它周的安排。"""
        entry = await self.get_entry(entry_id)
        if data.semester_start.weekday() != 0:
            raise ApiError(ErrorCode.VALIDATION_ERROR, "学期起始日必须是周一")

        def week_of(day: date) -> int:
            return (day - data.semester_start).days // 7 + 1

        source_week = week_of(data.source_date)
        target_week = week_of(data.target_date)
        if not 1 <= source_week <= 30 or not 1 <= target_week <= 30:
            raise ApiError(ErrorCode.VALIDATION_ERROR, "调课日期必须在第 1 至 30 教学周内")
        weeks = list(entry.weeks or DEFAULT_WEEKS)
        if data.source_date.weekday() + 1 != entry.weekday or source_week not in weeks:
            raise ApiError(ErrorCode.CONFLICT, "原课程日期已变化，请刷新课表后重试")
        if data.source_date == data.target_date:
            raise ApiError(ErrorCode.VALIDATION_ERROR, "请选择不同的目标日期")

        target_weekday = data.target_date.weekday() + 1
        candidates = await self.list_entries(
            course_id=entry.course_id, weekday=target_weekday, week=target_week
        )
        for candidate in candidates:
            if candidate.id != entry.id and candidate.start_time == entry.start_time:
                raise ApiError(ErrorCode.CONFLICT, "目标日期已有这门课的同一时段")
        if target_weekday == entry.weekday and target_week in weeks:
            raise ApiError(ErrorCode.CONFLICT, "目标日期已经有这节课")

        if len(weeks) == 1:
            entry.weekday = target_weekday
            assign_weeks(entry, [target_week])
            moved = entry
        else:
            assign_weeks(entry, [week for week in weeks if week != source_week])
            moved = ScheduleEntry(
                course_id=entry.course_id,
                weekday=target_weekday,
                period=entry.period,
                start_time=entry.start_time,
                end_time=entry.end_time,
                location=entry.location,
                source=entry.source,
                confirmed=entry.confirmed,
            )
            assign_weeks(moved, [target_week])
            moved.course = entry.course
            self.session.add(moved)
        await self.session.flush()
        return moved

    def entry_to_response(self, entry: ScheduleEntry) -> ScheduleEntryResponse:
        """将 ORM 转换为 Response DTO（周次集合 list[int] + 派生位图）。"""
        weeks = list(entry.weeks or [])
        bitmap = entry.weeks_bitmap or weeks_to_bitmap(weeks)
        return ScheduleEntryResponse(
            id=entry.id,
            course_id=entry.course_id,
            course_name=entry.course.name if entry.course else None,
            weekday=entry.weekday,
            period=entry.period,
            start_time=entry.start_time,
            end_time=entry.end_time,
            location=entry.location,
            weeks=weeks,
            parsed_weeks=weeks,
            weeks_bitmap=bitmap,
            source=entry.source,
            confirmed=entry.confirmed,
            created_at=entry.created_at,
        )

    # 视觉 Provider 的「配置类」错误码：归为「未配置 / 不可用」，而非「调用失败」，
    # 让用户一眼分清「没配好」与「上游抖动」。
    _VISION_CONFIG_CODES = frozenset(
        {
            int(ErrorCode.PROVIDER_CONFIG_ERROR),
            int(ErrorCode.PROVIDER_NOT_FOUND),
            int(ErrorCode.PROVIDER_UNAVAILABLE),
        }
    )

    async def ocr_import(self, image_path: str) -> ScheduleOCRResponse:
        """从课表截图进行 OCR 识别，输出待确认条目列表。

        错误语义（**不再静默吞异常**）：

        - 未装配视觉 Provider（未配置 / 构造失败）→ 抛
          ``ApiError(VISION_PROVIDER_UNAVAILABLE)``（HTTP 503）。
        - 视觉 Provider 调用失败（网络 / 鉴权 / 超时 / 模型名错）→ 抛
          ``ApiError(VISION_CALL_FAILED)``（HTTP 502），消息附**原始异常类型与摘要**
          （已脱敏 + 截断，不泄露 api_key）。
        - 调用成功但**未**识别出条目 → **正常返回**，用 ``status`` / ``notice``
          区分「没识别到（empty）」与「取到原文但没能结构化（unstructured）」。
        """
        ocr_prompt = (
            "你是一个大学课表识别助手。请从课表截图中提取出所有课程安排，并输出为 JSON 格式。\n"
            "每一项包含：course_name（课程名）、teacher（授课老师，无则null）、"
            "weekday（星期几，数字1-7）、period（大节节次，数字1-12）、"
            "start_time（开始时间如 '08:00'，无则null）、end_time（结束时间如 '09:40'，无则null）、"
            "location（上课教室或地点，无则null）、weeks（周次区间字符串如 '1-16' 或 '1-8,10-16'）。\n"
            "请严格以 JSON 列表格式输出，如：\n"
            '[{"course_name": "工程力学", "teacher": "李老师", "weekday": 1, "period": 1, "start_time": "08:30", "end_time": "10:05", "location": "工科楼201", "weeks": "1-16"}]'
        )

        # 1) 视觉 Provider 未装配 → 明确报「未配置」，绝不返回空列表冒充成功。
        if self.vision is None:
            raise ApiError(
                ErrorCode.VISION_PROVIDER_UNAVAILABLE,
                "未配置可用的视觉（多模态）模型，课表 OCR 无法执行。"
                "请在 config.local.yaml / config.cloud.yaml 的 providers.cloud_vision 中填写 "
                "api_key / base_url / model；若改用本地多模态，请将 vision_provider 指向 "
                "local_vision 并在 providers.local_vision 中填写 model_name。",
            )

        # 2) 调用视觉 Provider（成功=拿到原文；失败=抛出，绝不吞成「没内容」）。
        try:
            extracted_text = await self.vision.read_image(image_path, ocr_prompt) or ""
        except ProviderError as exc:
            _log.warning(
                "schedule_ocr_vision_failed",
                provider=exc.provider,
                error_code=int(exc.code),
                error_type=type(exc).__name__,
                error=_redact(_truncate(str(exc))),
            )
            raise self._vision_error_to_api_error(exc) from exc
        except Exception as exc:  # noqa: BLE001 - 归一为可读错误，绝不静默
            _log.warning(
                "schedule_ocr_vision_unexpected",
                error_type=type(exc).__name__,
                error=_redact(_truncate(str(exc))),
            )
            raise ApiError(
                ErrorCode.VISION_CALL_FAILED,
                f"视觉（多模态）模型调用失败（{type(exc).__name__}）："
                f"{_redact(_truncate(str(exc)))}",
            ) from exc

        # 3) 直接结构化解析。
        items: list[ScheduleOCRItem] = []
        if extracted_text:
            items = self._parse_ocr_json(extracted_text)

        # 4) 直接解析失败时，尝试 LLM 兜底纠正（失败**记录日志**，不静默吞）。
        if not items and extracted_text and self.llm is not None:
            try:
                resp = await self.llm.complete(
                    [
                        LLMMessage(role="system", content="将用户给出的课表文本转成合规的 JSON 数组。"),
                        LLMMessage(role="user", content=f"课表文本：\n{extracted_text}"),
                    ],
                    options=LLMOptions(json_mode=True),
                )
                items = self._parse_ocr_json(resp)
            except Exception as exc:  # noqa: BLE001 - 兜底失败不阻断，但必须可见
                _log.warning(
                    "schedule_ocr_llm_fallback_failed",
                    error_type=type(exc).__name__,
                    error=_redact(_truncate(str(exc))),
                )

        # 5) 结局判定：区分「没识别到」与「跑起来了但没能结构化」。
        if items:
            return ScheduleOCRResponse(items=items, raw_text=extracted_text, status="ok")
        if extracted_text:
            return ScheduleOCRResponse(
                items=[],
                raw_text=extracted_text,
                status="unstructured",
                notice=(
                    "已获取截图文字，但未能结构化出课表条目（可能截图清晰度不足或版式特殊）。"
                    "请核对下方原文，或改为手动录入。"
                ),
            )
        return ScheduleOCRResponse(
            items=[],
            raw_text="",
            status="empty",
            notice=(
                "未能从截图中识别到任何文字 / 课表条目。请确认上传的是清晰的课表截图，"
                "或改为手动录入。"
            ),
        )

    def _vision_error_to_api_error(self, exc: ProviderError) -> ApiError:
        """把视觉 ProviderError 归一为**用户可读、可自诊**的 ApiError。"""
        summary = _redact(_truncate(str(exc)))
        if int(exc.code) in self._VISION_CONFIG_CODES:
            return ApiError(
                ErrorCode.VISION_PROVIDER_UNAVAILABLE,
                "视觉（多模态）模型不可用或未配置完成，课表 OCR 无法执行。"
                f"原始错误（{type(exc).__name__}/{exc.provider}）：{summary}。"
                "请在 config.local.yaml / config.cloud.yaml 的 providers.cloud_vision 中"
                "填写 api_key / base_url / model 后重试。",
            )
        return ApiError(
            ErrorCode.VISION_CALL_FAILED,
            f"视觉（多模态）模型调用失败（{type(exc).__name__}/{exc.provider}）：{summary}",
        )

    def _parse_ocr_json(self, text: str) -> list[ScheduleOCRItem]:
        """从字符串中寻找并解析 JSON 列表。"""
        cleaned = text.strip()
        if cleaned.startswith("```"):
            cleaned = cleaned.strip("`")
            if "\n" in cleaned:
                cleaned = cleaned.split("\n", 1)[1]
            cleaned = cleaned.strip()

        start = cleaned.find("[")
        end = cleaned.rfind("]")
        if start != -1 and end != -1 and end > start:
            json_str = cleaned[start : end + 1]
            try:
                data = json.loads(json_str)
                if isinstance(data, list):
                    res = []
                    for d in data:
                        if isinstance(d, dict) and "course_name" in d and "weekday" in d:
                            res.append(
                                ScheduleOCRItem(
                                    course_name=str(d.get("course_name")),
                                    teacher=d.get("teacher"),
                                    weekday=int(d.get("weekday", 1)),
                                    period=int(d.get("period", 1)),
                                    start_time=d.get("start_time"),
                                    end_time=d.get("end_time"),
                                    location=d.get("location"),
                                    weeks=str(d.get("weeks", "1-16")),
                                )
                            )
                    return res
            except Exception:
                pass
        return []

    async def confirm_entries(self, request: ScheduleConfirmRequest) -> list[ScheduleEntry]:
        """批量确认并持久化 OCR 导入的课表条目。"""
        created_entries: list[ScheduleEntry] = []
        for item in request.entries:
            # 查找或新建对应课程
            stmt = select(Course).where(Course.name == item.course_name.strip())
            result = await self.session.execute(stmt)
            course = result.scalars().first()
            if not course:
                course = Course(
                    name=item.course_name.strip(),
                    semester=request.semester,
                    teacher=item.teacher.strip() if item.teacher else None,
                )
                self.session.add(course)
                await self.session.flush()

            entry = ScheduleEntry(
                course_id=course.id,
                weekday=item.weekday,
                period=item.period,
                start_time=item.start_time,
                end_time=item.end_time,
                location=item.location,
                source="ocr",
                confirmed=True,
            )
            assign_weeks(entry, item.weeks)
            self.session.add(entry)
            created_entries.append(entry)

        await self.session.flush()
        # 预加载 course
        for entry in created_entries:
            await self.session.refresh(entry, attribute_names=["course"])
        return created_entries

    # ------------------------------------------------------------------
    # ICS 课表导入（架构设计 §3.9.2，T1-04）
    # ------------------------------------------------------------------

    # 无 DESCRIPTION 时按开始时间兜底映射到「第几大节」（基于 standard_815 作息）
    _SLOT_START_MINUTES: tuple[tuple[int, int], ...] = (
        (8, 15),
        (10, 5),
        (14, 15),
        (16, 0),
        (19, 30),
    )

    async def import_ics(
        self,
        ics_path: str,
        *,
        semester: str | None = None,
        semester_start: date | None = None,
        mode: str = "merge",
        confirmed: bool = True,
    ) -> ScheduleImportResult:
        """把 ``.ics`` 课表文件导入为课程 + 课表条目（架构设计 §3.9.2）。

        流程：

        1. 解析 ICS，逐个 ``VEVENT`` 展开其 ``RRULE``（WEEKLY）为发生日；
        2. 按 ``(课程名, 星期, 节次)`` **合并**同一门课的多条时间片，周次取**并集**
           （由此表达单/双周与停课断档）；
        3. ``mode='merge'``（默认）跳过已存在的 ``(课程, 星期, 节次)``；
           ``mode='replace'`` 先清空该学期既有课程与课表再导入。

        :param semester_start: 学期首日（周一），把发生日换算成教学周次；
            缺省 ``DEFAULT_SEMESTER_START``（2026-08-31）。

        节次换算：DESCRIPTION 中的「第X - Y节」为**小节**区间，
        取 ``period = (X + 1) // 2`` 映射为「大节」（如 第1-2节→大节1，第3-4节→大节2）。
        """
        try:
            from icalendar import Calendar  # 延迟导入：仅此功能依赖
        except ImportError as exc:  # pragma: no cover - 依赖缺失时的明确提示
            raise ApiError(
                ErrorCode.SCHEDULE_ERROR,
                "缺少 icalendar 依赖，无法解析 .ics 文件。请先安装 icalendar>=6.0。",
            ) from exc

        if mode not in ("merge", "replace"):
            raise ApiError(ErrorCode.VALIDATION_ERROR, f"不支持的导入模式：{mode}")

        start_date = semester_start or DEFAULT_SEMESTER_START
        semester = semester or "2026秋"

        with open(ics_path, "rb") as fh:
            raw_bytes = fh.read()
        try:
            calendar = Calendar.from_ical(raw_bytes)
        except Exception as exc:  # noqa: BLE001 - 归一为可读错误
            raise ApiError(
                ErrorCode.SCHEDULE_ERROR, f"ICS 文件解析失败：{_truncate(str(exc))}"
            ) from exc

        # 1) 展开 + 合并
        merged: dict[tuple[str, int, int], dict[str, Any]] = {}
        course_meta: dict[str, dict[str, Any]] = {}
        for component in calendar.walk("VEVENT"):
            summary = str(component.get("SUMMARY", "")).strip()
            if not summary:
                continue
            dtstart_date, start_hm = self._ics_datetime(component.get("DTSTART"))
            if dtstart_date is None:
                continue
            _, end_hm = self._ics_datetime(component.get("DTEND"))
            location = str(component.get("LOCATION", "")).strip() or None
            description = str(component.get("DESCRIPTION", ""))

            weeks = self._ics_occurrence_weeks(
                component, dtstart_date, start_hm, start_date
            )
            if not weeks:
                continue

            sect_start, _ = self._ics_sections(description, start_hm)
            period = (sect_start + 1) // 2
            weekday = dtstart_date.isoweekday()

            key = (summary, weekday, period)
            record = merged.get(key)
            if record is None:
                merged[key] = {
                    "weekday": weekday,
                    "period": period,
                    "start_time": start_hm,
                    "end_time": end_hm,
                    "location": location,
                    "weeks": set(weeks),
                }
            else:
                record["weeks"].update(weeks)
                record["start_time"] = record["start_time"] or start_hm
                record["end_time"] = record["end_time"] or end_hm
                record["location"] = record["location"] or location

            meta = course_meta.setdefault(summary, {"teacher": None})
            teacher = self._ics_teacher(description)
            if teacher and not meta["teacher"]:
                meta["teacher"] = teacher

        # 2) replace 模式：先清空该学期
        if mode == "replace":
            old_courses = list(
                (await self.session.execute(select(Course).where(Course.semester == semester)))
                .scalars()
                .all()
            )
            for old in old_courses:
                old_entries = (
                    await self.session.execute(
                        select(ScheduleEntry).where(ScheduleEntry.course_id == old.id)
                    )
                ).scalars().all()
                for old_entry in old_entries:
                    await self.session.delete(old_entry)
                await self.session.delete(old)
            await self.session.flush()

        # 3) 建/取课程，逐条建课表；merge 模式去重
        existing_courses: dict[str, Course] = {}
        existing_keys: set[tuple[str, int, int]] = set()
        for course in (
            await self.session.execute(select(Course).where(Course.semester == semester))
        ).scalars().all():
            existing_courses[course.name] = course
            for entry in (
                await self.session.execute(
                    select(ScheduleEntry).where(ScheduleEntry.course_id == course.id)
                )
            ).scalars().all():
                existing_keys.add((course.name, entry.weekday, entry.period))

        skipped: list[ScheduleImportDuplicateItem] = []
        involved: set[str] = set()
        created = 0

        for (name, weekday, period), rec in merged.items():
            involved.add(name)
            course = existing_courses.get(name)
            if course is None:
                course = Course(
                    name=name,
                    semester=semester,
                    teacher=course_meta.get(name, {}).get("teacher"),
                    auto_record=False,
                )
                self.session.add(course)
                await self.session.flush()
                existing_courses[name] = course

            if (name, weekday, period) in existing_keys:
                skipped.append(
                    ScheduleImportDuplicateItem(
                        course_name=name, weekday=weekday, period=period
                    )
                )
                continue

            entry = ScheduleEntry(
                course_id=course.id,
                weekday=weekday,
                period=period,
                start_time=rec["start_time"],
                end_time=rec["end_time"],
                location=rec["location"],
                source="import",
                confirmed=confirmed,
            )
            assign_weeks(entry, sorted(rec["weeks"]))
            self.session.add(entry)
            existing_keys.add((name, weekday, period))
            created += 1

        await self.session.flush()

        _log.info(
            "schedule_ics_imported",
            semester=semester,
            mode=mode,
            courses=len(involved),
            entries=created,
            skipped=len(skipped),
        )

        return ScheduleImportResult(
            source="ics",
            semester=semester,
            semester_start=start_date.isoformat(),
            mode=mode,
            courses_count=len(involved),
            entries_count=created,
            courses=sorted(involved),
            skipped=skipped,
        )

    @staticmethod
    def _ics_datetime(prop: Any) -> tuple[date | None, str | None]:
        """按 ICS **原始裸值**解析出 ``(本地日期, 'HH:MM')``。

        直接解析 ``to_ical()``（如 ``20260902T100500``），绕开 icalendar 对
        ``TZID=/Asia/Shanghai`` 的时区换算，确保日期/墙钟时间与源文件一致。
        """
        if prop is None:
            return None, None
        raw = prop.to_ical()
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "ignore")
        raw = raw.strip()
        date_part = raw[:8]
        if len(date_part) != 8 or not date_part.isdigit():
            return None, None
        try:
            local_date = date(
                int(date_part[0:4]), int(date_part[4:6]), int(date_part[6:8])
            )
        except ValueError:
            return None, None
        time_str: str | None = None
        if "T" in raw and len(raw) >= 13:
            hh, mm = raw[9:11], raw[11:13]
            if hh.isdigit() and mm.isdigit():
                time_str = f"{hh}:{mm}"
        return local_date, time_str

    @staticmethod
    def _parse_hm(hm: str | None) -> time | None:
        """``'HH:MM'`` → :class:`datetime.time`；非法返回 ``None``。"""
        if not hm or ":" not in hm:
            return None
        try:
            hh, mm = hm.split(":", 1)
            return time(int(hh), int(mm))
        except ValueError:
            return None

    @staticmethod
    def _to_local_naive(value: Any) -> datetime | None:
        """把 RRULE ``UNTIL``（UTC）转换为**本地墙钟**的 naive datetime。"""
        if isinstance(value, datetime):
            if value.tzinfo is not None:
                return value.astimezone(_ICS_TZ).replace(tzinfo=None)
            return value
        if isinstance(value, date):
            return datetime.combine(value, time(23, 59, 59))
        return None

    @staticmethod
    def _ics_sections(description: str, start_hm: str | None) -> tuple[int, int]:
        """从 DESCRIPTION 解析「第X - Y节」→ ``(起小节, 止小节)``；失败按时间兜底。"""
        text = (description or "").replace("\\n", "\n")
        match = re.search(r"第\s*(\d+)\s*[-–~至]\s*(\d+)\s*节", text)
        if match:
            return int(match.group(1)), int(match.group(2))
        single = re.search(r"第\s*(\d+)\s*节", text)
        if single:
            value = int(single.group(1))
            return value, value
        period = ScheduleService._period_from_time(start_hm)
        return period * 2 - 1, period * 2

    @classmethod
    def _period_from_time(cls, hm: str | None) -> int:
        """按开始时间就近匹配第几大节（无 DESCRIPTION 时的兜底）。"""
        parsed = cls._parse_hm(hm)
        if parsed is None:
            return 1
        minutes = parsed.hour * 60 + parsed.minute
        best, best_diff = 1, None
        for idx, (hh, mm) in enumerate(cls._SLOT_START_MINUTES, start=1):
            diff = abs(minutes - (hh * 60 + mm))
            if best_diff is None or diff < best_diff:
                best, best_diff = idx, diff
        return best

    @staticmethod
    def _ics_teacher(description: str) -> str | None:
        """从 DESCRIPTION 末行取授课教师；末行含数字（多为教室）则弃用。"""
        text = (description or "").replace("\\n", "\n")
        lines = [line.strip() for line in text.split("\n")]
        lines = [line for line in lines if line]
        if not lines:
            return None
        last = lines[-1]
        if re.search(r"节", last) or re.search(r"\d", last):
            return None
        return last

    @staticmethod
    def _ics_occurrence_weeks(
        component: Any,
        start_date: date,
        start_hm: str | None,
        semester_start: date,
    ) -> list[int]:
        """展开 VEVENT 的 ``RRULE``（WEEKLY）为**教学周次集合**（去重升序）。"""
        interval = 1
        until_local: datetime | None = None
        rrule = component.get("RRULE")
        if rrule is not None:
            raw_interval = rrule.get("INTERVAL")
            if raw_interval is not None:
                if isinstance(raw_interval, (list, tuple)):
                    raw_interval = raw_interval[0]
                try:
                    interval = max(int(raw_interval), 1)
                except (TypeError, ValueError):
                    interval = 1
            raw_until = rrule.get("UNTIL")
            if raw_until is not None:
                if isinstance(raw_until, (list, tuple)):
                    raw_until = raw_until[0]
                until_local = ScheduleService._to_local_naive(raw_until)

        start_time_obj = ScheduleService._parse_hm(start_hm) or time(0, 0)
        weeks: set[int] = set()
        cursor = start_date
        for _ in range(60):  # 上限保护（≈60 周）
            occ_dt = datetime.combine(cursor, start_time_obj)
            if until_local is not None and occ_dt > until_local:
                break
            week = ((cursor - semester_start).days // 7) + 1
            if week >= 1:
                weeks.add(week)
            cursor = cursor + timedelta(days=7 * interval)
        return sorted(weeks)
