"""录音登记、分片上传与存储管理服务（架构设计 §1.2、T2-01，ADR-003）。"""

from __future__ import annotations

import shutil
import json
from pathlib import Path
from typing import Any
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import AppConfig, get_app_config
from app.core.ids import local_now
from app.db.models import Course, Recording, ScheduleEntry
from app.errors import ApiError, ErrorCode
from app.schemas.recording import ChunkUploadResponse, RecordingCreate
from app.services.recording_filename import native_recording_start, recording_destination

__all__ = ["RecordingService"]


class RecordingService:
    """录音管理与文件落地服务。"""

    def __init__(self, session: AsyncSession, config: AppConfig | None = None) -> None:
        self.session = session
        self.config = config or get_app_config()
        self.storage_root = Path(self.config.resolved_storage_root)
        self.recordings_dir = Path(getattr(self.config, "resolved_recordings_root",
                                           self.storage_root / "recordings"))
        self.chunks_base_dir = self.storage_root / "tmp_chunks"

    async def get_recording(self, recording_id: str) -> Recording:
        """获取录音记录，不存在抛出 404。"""
        stmt = (
            select(Recording)
            .options(selectinload(Recording.course), selectinload(Recording.transcript))
            .where(Recording.id == recording_id)
        )
        result = await self.session.execute(stmt)
        rec = result.scalars().first()
        if not rec:
            raise ApiError(ErrorCode.NOT_FOUND, f"录音记录不存在：{recording_id}")
        return rec

    async def list_recordings(
        self,
        *,
        course_id: str | None = None,
        upload_status: str | None = None,
        transcription_status: str | None = None,
    ) -> list[Recording]:
        """按条件查询录音列表。"""
        stmt = (
            select(Recording)
            .options(selectinload(Recording.course))
            .order_by(Recording.created_at.desc())
        )
        if course_id:
            stmt = stmt.where(Recording.course_id == course_id)
        if upload_status:
            stmt = stmt.where(Recording.upload_status == upload_status)
        if transcription_status:
            stmt = stmt.where(Recording.transcription_status == transcription_status)

        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def create_recording(self, data: RecordingCreate) -> Recording:
        """登记新录音。"""
        course = await self.session.get(Course, data.course_id)
        if not course:
            raise ApiError(ErrorCode.NOT_FOUND, f"关联课程不存在：{data.course_id}")

        if data.schedule_entry_id:
            entry = await self.session.get(ScheduleEntry, data.schedule_entry_id)
            if not entry:
                raise ApiError(
                    ErrorCode.NOT_FOUND, f"关联排课条目不存在：{data.schedule_entry_id}"
                )

        rec = Recording(
            course_id=data.course_id,
            schedule_entry_id=data.schedule_entry_id,
            started_at=data.started_at or local_now(),
            ended_at=data.ended_at,
            duration_ms=data.duration_ms,
            codec=data.codec.lower(),
            size_bytes=data.size_bytes,
            upload_status="pending",
            transcription_status="pending",
        )
        self.session.add(rec)
        await self.session.flush()
        rec.course = course
        return rec

    async def save_chunk(
        self,
        recording_id: str,
        chunk_index: int,
        chunk_bytes: bytes,
        total_chunks: int | None = None,
    ) -> ChunkUploadResponse:
        """保存单分片到临时目录。"""
        await self.get_recording(recording_id)

        target_dir = self.chunks_base_dir / recording_id
        target_dir.mkdir(parents=True, exist_ok=True)
        manifest = target_dir / "upload.json"
        recorded_total = json.loads(manifest.read_text("utf-8"))["total_chunks"] if manifest.exists() else None
        if chunk_index < 0 or (total_chunks is not None and (total_chunks <= 0 or chunk_index >= total_chunks)):
            raise ApiError(ErrorCode.VALIDATION_ERROR, "分片索引或总数不正确")
        if recorded_total is not None and total_chunks is not None and recorded_total != total_chunks:
            raise ApiError(ErrorCode.VALIDATION_ERROR, "同一录音的分片总数不能改变")
        expected = recorded_total if recorded_total is not None else total_chunks
        if expected is not None:
            if chunk_index >= expected:
                raise ApiError(ErrorCode.VALIDATION_ERROR, "分片索引超出已登记总数")
            temp = manifest.with_suffix(".tmp")
            temp.write_text(json.dumps({"total_chunks": expected}), "utf-8")
            temp.replace(manifest)

        chunk_file = target_dir / f"chunk_{chunk_index:05d}.part"
        chunk_file.write_bytes(chunk_bytes)

        # 检查当前收到多少分片
        received_chunks = list(target_dir.glob("chunk_*.part"))
        is_completed = (
            expected is not None and {p.name for p in received_chunks} == {f"chunk_{i:05d}.part" for i in range(expected)}
        )

        return ChunkUploadResponse(
            recording_id=recording_id,
            chunk_index=chunk_index,
            received_bytes=len(chunk_bytes),
            total_chunks=total_chunks,
            is_completed=is_completed,
        )

    async def complete_upload(self, recording_id: str) -> Recording:
        """将分片按序合并为一个完整音频文件并持久化。"""
        rec = await self.get_recording(recording_id)
        chunks_dir = self.chunks_base_dir / recording_id

        if not chunks_dir.exists():
            raise ApiError(ErrorCode.VALIDATION_ERROR, f"未找到该录音的分片数据：{recording_id}")

        chunk_files = sorted(chunks_dir.glob("chunk_*.part"))
        if not chunk_files:
            raise ApiError(ErrorCode.VALIDATION_ERROR, "分片列表为空")
        manifest = chunks_dir / "upload.json"
        expected = json.loads(manifest.read_text("utf-8"))["total_chunks"] if manifest.exists() else len(chunk_files)
        if {p.name for p in chunk_files} != {f"chunk_{i:05d}.part" for i in range(expected)}:
            raise ApiError(ErrorCode.VALIDATION_ERROR, "音频分片尚未完整接收，不能合并或开始转写")

        self.recordings_dir.mkdir(parents=True, exist_ok=True)
        ext = rec.codec or "aac"
        final_file = recording_destination(self.recordings_dir, rec.course.name,
                                           rec.started_at or local_now(), ext, rec.file_path)
        temporary_file = self.recordings_dir / f"{recording_id}.incoming"

        total_size = 0
        with temporary_file.open("wb") as outfile:
            for cfile in chunk_files:
                data = cfile.read_bytes()
                outfile.write(data)
                total_size += len(data)
        temporary_file.replace(final_file)

        # 清理分片临时目录
        shutil.rmtree(chunks_dir, ignore_errors=True)

        rec.file_path = str(final_file.resolve())
        rec.size_bytes = total_size
        rec.upload_status = "uploaded"
        await self.session.flush()

        return rec

    async def save_direct_file(
        self, recording_id: str, file_bytes: bytes, filename: str
    ) -> Recording:
        """单文件整传（用于非分片直接上传场景）。"""
        rec = await self.get_recording(recording_id)
        self.recordings_dir.mkdir(parents=True, exist_ok=True)

        ext = Path(filename).suffix.lstrip(".") or rec.codec or "aac"
        recorded_start = native_recording_start(filename)
        if recorded_start:
            rec.started_at = recorded_start
        final_file = recording_destination(self.recordings_dir, rec.course.name,
                                           rec.started_at or local_now(), ext, rec.file_path)
        temporary_file = self.recordings_dir / f"{recording_id}.incoming"
        temporary_file.write_bytes(file_bytes)
        temporary_file.replace(final_file)

        rec.file_path = str(final_file.resolve())
        rec.size_bytes = len(file_bytes)
        rec.codec = ext.lower()
        rec.upload_status = "uploaded"
        await self.session.flush()

        return rec

    async def delete_physical_audio(self, recording_id: str) -> None:
        """转写成功后安全删除物理音频文件（ADR-003 / FR-15）。"""
        rec = await self.get_recording(recording_id)
        if rec.file_path:
            audio_path = Path(rec.file_path)
            if audio_path.exists():
                audio_path.unlink(missing_ok=True)

        rec.file_path = None
        rec.deleted_at = local_now()
        await self.session.flush()
