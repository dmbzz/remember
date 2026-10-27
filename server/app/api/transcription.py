"""转写任务与文本管理 API 路由（架构设计 §3.4，T2-02、T2-03）。"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.deps import get_db, get_task_queue, get_transcription_provider
from app.providers.base import TranscriptionProvider
from app.schemas.common import ok
from app.schemas.transcription import (
    TranscriptionCreateRequest,
)
from app.services.transcription_service import TranscriptionService

__all__ = ["router"]

router = APIRouter(tags=["transcription"])


def _transcription_service(
    session: AsyncSession = Depends(get_db),
) -> TranscriptionService:
    try:
        provider = get_transcription_provider()
    except Exception:
        provider = None
    queue = get_task_queue()
    return TranscriptionService(
        session=session, task_queue=queue, transcription_provider=provider
    )


@router.post("/transcriptions", summary="提交转写任务（异步队列）")
async def submit_transcription(
    payload: TranscriptionCreateRequest,
    service: TranscriptionService = Depends(_transcription_service),
) -> dict:
    """提交已上传录音的转写请求，进入异步任务队列排队执行。"""
    task = await service.enqueue_transcription(
        recording_id=payload.recording_id,
        provider_name=payload.provider,
        lesson=payload.lesson,
    )
    return ok(task.model_dump(), message="转写任务已提交")


@router.get("/transcriptions", summary="查询转写任务队列列表")
async def list_transcription_tasks(
    status: str | None = Query(None, description="pending / running / success / failed"),
    service: TranscriptionService = Depends(_transcription_service),
) -> dict:
    """查询当前队列中的转写作业列表与执行进度。"""
    tasks = await service.list_tasks(status=status)
    return ok([t.model_dump() for t in tasks])


@router.get("/transcriptions/{transcript_id}", summary="获取转写结果详情与勘误表")
async def get_transcript(
    transcript_id: str,
    service: TranscriptionService = Depends(_transcription_service),
) -> dict:
    """根据 ID 获取已完成的转写正文、清洗后正文及勘误表。"""
    trs = await service.get_transcript(transcript_id)
    return ok(service.transcript_to_response(trs).model_dump())


@router.post("/transcriptions/{recording_id}/retry", summary="重试转写任务")
async def retry_transcription(
    recording_id: str,
    provider: str | None = None,
    service: TranscriptionService = Depends(_transcription_service),
) -> dict:
    """重新排队执行先前失败的转写任务。"""
    task = await service.enqueue_transcription(
        recording_id=recording_id,
        provider_name=provider,
    )
    return ok(task.model_dump(), message="重试任务已提交")
