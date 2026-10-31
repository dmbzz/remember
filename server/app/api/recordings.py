"""录音管理与上传 API 路由（架构设计 §3.4，T2-01）。"""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, File, Form, Query, UploadFile, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.deps import get_db
from app.schemas.common import ok
from app.schemas.recording import RecordingCreate, RecordingResponse
from app.services.recording_service import RecordingService
from app.services.asr_jobs import enqueue_uploaded
from app.services.upload_progress import reception_progress

__all__ = ["router"]

router = APIRouter(tags=["recordings"])


@router.post("/recordings", summary="登记新录音")
async def create_recording(
    payload: RecordingCreate,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """移动端开始录音或录音结束时登记元数据。"""
    service = RecordingService(session)
    rec = await service.create_recording(payload)
    return ok(RecordingResponse.model_validate(rec).model_dump(), message="录音登记成功")


@router.post("/recordings/{recording_id}/upload", summary="分片上传音频数据")
async def upload_recording_chunk(
    recording_id: str,
    chunk_index: int = Form(..., description="分片索引，从 0 开始"),
    total_chunks: int | None = Form(None, description="总分片数"),
    file: UploadFile = File(..., description="分片二进制数据"),
    session: AsyncSession = Depends(get_db),
) -> dict:
    """上传大音频文件的单个分片。"""
    service = RecordingService(session)
    content = await file.read()
    result = await service.save_chunk(
        recording_id=recording_id,
        chunk_index=chunk_index,
        chunk_bytes=content,
        total_chunks=total_chunks,
    )
    return ok(result.model_dump(), message=f"分片 {chunk_index} 接收成功")


@router.post("/recordings/{recording_id}/upload-file", summary="整文件直传音频")
async def upload_recording_file(
    recording_id: str,
    request: Request,
    file: UploadFile = File(..., description="音频文件（如 aac, wav, m4a）"),
    session: AsyncSession = Depends(get_db),
) -> dict:
    """单文件直接上传（针对小型录音或已在本地的录音文件）。"""
    service = RecordingService(session)
    content = await file.read()
    dispatcher = getattr(request.app.state, "asr_dispatcher", None)
    # Serialize final source replacement and its durable receipt with task deletion.
    async with dispatcher.mutations if dispatcher else asyncio.Lock():
        rec = await service.save_direct_file(
            recording_id=recording_id,
            file_bytes=content,
            filename=file.filename or "audio.aac",
        )
        await enqueue_uploaded(session, rec)
        await session.commit()
        if dispatcher:
            dispatcher.wake.set()
    return ok(RecordingResponse.model_validate(rec).model_dump(), message="音频上传落地成功")


@router.post("/recordings/{recording_id}/complete", summary="完成分片上传并合并落地")
async def complete_recording_upload(
    recording_id: str,
    request: Request,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """所有分片上传完成后调用此接口触发服务端合并组装。"""
    service = RecordingService(session)
    dispatcher = getattr(request.app.state, "asr_dispatcher", None)
    async with dispatcher.mutations if dispatcher else asyncio.Lock():
        rec = await service.complete_upload(recording_id)
        await enqueue_uploaded(session, rec)
        await session.commit()
        if dispatcher:
            dispatcher.wake.set()
    return ok(RecordingResponse.model_validate(rec).model_dump(), message="音频组装完成")


@router.get("/recordings", summary="查询录音记录列表")
async def list_recordings(
    course_id: str | None = None,
    upload_status: str | None = Query(None, description="pending / uploaded"),
    transcription_status: str | None = Query(
        None, description="pending / running / success / failed"
    ),
    session: AsyncSession = Depends(get_db),
) -> dict:
    """按课程、上传状态、转写状态查询录音。"""
    service = RecordingService(session)
    recordings = await service.list_recordings(
        course_id=course_id,
        upload_status=upload_status,
        transcription_status=transcription_status,
    )
    return ok([{**RecordingResponse.model_validate(r).model_dump(), "reception_progress": reception_progress(r)} for r in recordings])


@router.get("/recordings/{recording_id}", summary="获取单条录音详情")
async def get_recording(
    recording_id: str,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """根据 ID 获取录音详情。"""
    service = RecordingService(session)
    rec = await service.get_recording(recording_id)
    return ok(RecordingResponse.model_validate(rec).model_dump())
