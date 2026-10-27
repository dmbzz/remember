"""转写任务管理与流水线服务（架构设计 §1.2、T2-02、T2-03）。

职责：
1. 校验录音状态并提交转写任务至单 Worker 异步队列。
2. 调度 TranscriptionProvider 完成转写推理。
3. 执行幻觉清洗与学科术语校正（CorrectionService），生成勘误表。
4. 依据不可变契约（ADR-002）归档转写原文至 Obsidian 库并登记清单。
5. 按照 ADR-003 / FR-15 规则安全物理删除原始音频。
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import AppConfig, get_app_config
from app.core.ids import local_now, to_iso
from app.core.tasks import TaskQueue, TaskStatus, get_default_task_queue
from app.db.models import Course, Recording, Transcript
from app.db.session import get_database
from app.deps import get_registry
from app.errors import ApiError, ErrorCode
from app.providers.base import TranscriptionProvider
from app.schemas.transcription import (
    TranscriptResponse,
    TranscriptionTaskResponse,
)
from app.services.archive_service import ArchiveService
from app.services.correction_service import CorrectionService
from app.services.recording_service import RecordingService

__all__ = ["TranscriptionService"]


class TranscriptionService:
    """转写全流程管理服务。"""

    def __init__(
        self,
        session: AsyncSession,
        config: AppConfig | None = None,
        task_queue: TaskQueue | None = None,
        transcription_provider: TranscriptionProvider | None = None,
    ) -> None:
        self.session = session
        self.config = config or get_app_config()
        self.task_queue = task_queue or get_default_task_queue()
        self.provider = transcription_provider
        self.archive_service = ArchiveService(self.config)
        self.correction_service = CorrectionService()
        self.recording_service = RecordingService(self.session, self.config)

    async def get_transcript(self, transcript_id: str) -> Transcript:
        """根据 ID 获取转写记录。"""
        stmt = (
            select(Transcript)
            .options(selectinload(Transcript.recording))
            .where(Transcript.id == transcript_id)
        )
        result = await self.session.execute(stmt)
        trs = result.scalars().first()
        if not trs:
            raise ApiError(ErrorCode.NOT_FOUND, f"转写记录不存在：{transcript_id}")
        return trs

    async def get_transcript_by_recording(self, recording_id: str) -> Transcript | None:
        """根据录音 ID 获取对应转写记录。"""
        stmt = (
            select(Transcript)
            .options(selectinload(Transcript.recording))
            .where(Transcript.recording_id == recording_id)
        )
        result = await self.session.execute(stmt)
        return result.scalars().first()

    def transcript_to_response(self, trs: Transcript) -> TranscriptResponse:
        """转写 ORM 转为 Response DTO。"""
        # 计算理论归档路径供参考
        course_name = trs.recording.course.name if trs.recording and trs.recording.course else "未知课程"
        date_str = trs.recording.started_at.strftime("%Y-%m-%d") if trs.recording and trs.recording.started_at else local_now().strftime("%Y-%m-%d")
        archive_path = str(self.archive_service.transcript_path(course_name, 1, date_str))

        return TranscriptResponse(
            id=trs.id,
            recording_id=trs.recording_id,
            provider=trs.provider,
            raw_text=trs.raw_text,
            corrected_text=trs.corrected_text,
            errata=trs.errata or [],
            language=trs.language,
            duration_sec=trs.duration_sec,
            archive_path=archive_path,
            created_at=trs.created_at,
        )

    # -----------------------------------------------------------------------
    # 转写执行核心流水线
    # -----------------------------------------------------------------------
    async def execute_transcription(
        self,
        recording_id: str,
        provider_name: str | None = None,
        lesson: int | None = None,
    ) -> Transcript:
        """执行录音转写的完整闭环逻辑。"""
        rec = await self.recording_service.get_recording(recording_id)

        if rec.upload_status != "uploaded":
            raise ApiError(
                ErrorCode.VALIDATION_ERROR,
                f"录音尚未上传完成（upload_status={rec.upload_status}），无法转写",
            )

        if not rec.file_path or not Path(rec.file_path).exists():
            raise ApiError(
                ErrorCode.NOT_FOUND, f"音频物理文件不存在：{rec.file_path}"
            )

        # 1. 标记录音状态为 running
        rec.transcription_status = "running"
        await self.session.flush()

        # 2. 确定 Provider
        active_provider = self.provider
        if active_provider is None:
            registry = get_registry(self.config)
            p_name = provider_name or self.config.transcription_provider
            active_provider = registry.build_transcription(p_name)

        try:
            # 3. 驱动 Provider 转写
            result = await active_provider.transcribe(rec.file_path)

            # 4. 术语清洗与勘误表生成
            correction = await self.correction_service.correct_transcript(result.text)

            # 5. 计算课次与归档信息
            course = rec.course
            course_name = course.name if course else "通用课程"

            if lesson is None:
                # 自动顺推课次：查该课程历史已有多少条转写记录 + 1
                stmt = (
                    select(Transcript)
                    .join(Recording)
                    .where(Recording.course_id == rec.course_id)
                )
                prev_count = len((await self.session.execute(stmt)).scalars().all())
                lesson = prev_count + 1

            date_str = (rec.started_at or local_now()).strftime("%Y-%m-%d")

            # 6. 转写原文归档到 Obsidian 目录，并登记到已处理文件清单
            text_to_save = correction.corrected_text or correction.cleaned_text
            saved_file = self.archive_service.save_transcript_file(
                course_name=course_name,
                lesson=lesson,
                date_str=date_str,
                content=text_to_save,
            )
            self.archive_service.register_processed(
                transcript_filename=saved_file.name,
                course_name=course_name,
                class_date=date_str,
                note_name="（待生成）",
            )

            # 7. 保存/更新数据库 Transcript 记录
            stmt = select(Transcript).where(Transcript.recording_id == recording_id)
            trs = (await self.session.execute(stmt)).scalars().first()
            if not trs:
                trs = Transcript(
                    recording_id=recording_id,
                    provider=active_provider.name,
                    raw_text=result.text,
                    corrected_text=correction.corrected_text,
                    errata=correction.errata,
                    language=result.language or "zh",
                    duration_sec=result.duration_sec,
                )
                self.session.add(trs)
            else:
                trs.provider = active_provider.name
                trs.raw_text = result.text
                trs.corrected_text = correction.corrected_text
                trs.errata = correction.errata
                trs.language = result.language or "zh"
                trs.duration_sec = result.duration_sec

            # 8. 更新录音状态为 success
            rec.transcription_status = "success"
            await self.session.flush()

            # 9. 按照 ADR-003 / FR-15 安全删除物理音频文件
            await self.recording_service.delete_physical_audio(recording_id)

            await self.session.flush()
            trs.recording = rec
            return trs

        except Exception as exc:
            rec.transcription_status = "failed"
            await self.session.flush()
            raise ApiError(
                ErrorCode.PROVIDER_CALL_FAILED, f"录音转写失败：{exc}"
            ) from exc

    # -----------------------------------------------------------------------
    # 异步队列任务提交
    # -----------------------------------------------------------------------
    async def enqueue_transcription(
        self,
        recording_id: str,
        provider_name: str | None = None,
        lesson: int | None = None,
    ) -> TranscriptionTaskResponse:
        """向异步任务队列投递转写作业。"""
        rec = await self.recording_service.get_recording(recording_id)
        if rec.upload_status != "uploaded":
            raise ApiError(
                ErrorCode.VALIDATION_ERROR,
                f"录音未上传完成（upload_status={rec.upload_status}），不能提交转写",
            )

        rec.transcription_status = "pending"
        await self.session.flush()

        async def _job(payload: dict[str, Any]) -> dict[str, Any]:
            # 后台 Worker 独立 session 执行
            database = get_database(self.config)
            async with database.session() as bg_session:
                bg_service = TranscriptionService(
                    session=bg_session,
                    config=self.config,
                    transcription_provider=self.provider,
                )
                trs = await bg_service.execute_transcription(
                    recording_id=payload["recording_id"],
                    provider_name=payload.get("provider_name"),
                    lesson=payload.get("lesson"),
                )
                return {"transcript_id": trs.id, "recording_id": payload["recording_id"]}

        task_id = await self.task_queue.enqueue(
            name=f"transcribe_{recording_id}",
            handler=_job,
            payload={
                "recording_id": recording_id,
                "provider_name": provider_name,
                "lesson": lesson,
            },
        )

        return TranscriptionTaskResponse(
            task_id=task_id,
            recording_id=recording_id,
            status="pending",
            message="转写任务已成功入队",
            created_at=to_iso(local_now()),
        )

    async def list_tasks(self, status: str | None = None) -> list[TranscriptionTaskResponse]:
        """查询任务队列中的所有转写任务。"""
        t_status = TaskStatus(status) if status else None
        records = await self.task_queue.list(status=t_status)
        results = []
        for r in records:
            if r.name.startswith("transcribe_"):
                res_dict = r.result if isinstance(r.result, dict) else {}
                results.append(
                    TranscriptionTaskResponse(
                        task_id=r.id,
                        recording_id=r.payload.get("recording_id", ""),
                        status=r.status.value,
                        error=r.error,
                        transcript_id=res_dict.get("transcript_id"),
                        created_at=to_iso(r.created_at),
                    )
                )
        return results
