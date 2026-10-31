"""ASR setup is editable only on the Windows loopback interface."""
import asyncio
import json
import os
import subprocess
from datetime import datetime
from pathlib import Path

import httpx
from fastapi import APIRouter, Depends, Request, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.settings import _require_local
from app.config import AppConfig
from app.deps import get_config, get_db
from app.db.models import AsrJob, Recording
from app.errors import ApiError, ErrorCode
from app.schemas.common import ok
from app.services.asr_jobs import job_dict
from app.services.asr_task_files import delete_verified_audio
from app.services.asr_settings import (AsrSettings, detect_local, load_settings,
                                       public_settings, save_settings, validate_settings)

router = APIRouter(tags=["asr"])

from app.services.desktop_notifications import DesktopSettings, load_desktop_settings, save_desktop_settings

@router.get("/settings/desktop")
async def desktop_settings(request: Request, config: AppConfig = Depends(get_config)):
    _require_local(request, config)
    return ok(load_desktop_settings().model_dump())

@router.put("/settings/desktop")
async def update_desktop_settings(payload: DesktopSettings, request: Request, config: AppConfig = Depends(get_config)):
    _require_local(request, config)
    save_desktop_settings(payload)
    return ok(load_desktop_settings().model_dump())


class AsrUpdate(AsrSettings):
    clear_api_key: bool = False


def merged(payload: AsrUpdate) -> AsrSettings:
    # Empty password field preserves the configured key; it is never returned.
    old = load_settings()
    data = payload.model_dump(exclude={"clear_api_key"})
    if 'managed_id' not in payload.model_fields_set:
        data['managed_id'] = old.managed_id
    if payload.clear_api_key:
        data["api_key"] = ""
    elif not payload.api_key:
        if old.api_key and old.base_url != payload.base_url and payload.mode == "qwen_service":
            raise ApiError(ErrorCode.VALIDATION_ERROR, "服务地址已变化，请重新输入密钥或勾选清除密钥")
        data["api_key"] = old.api_key
    return AsrSettings.model_validate(data)


@router.get("/settings/asr")
async def settings(request: Request, config: AppConfig = Depends(get_config)):
    _require_local(request, config)
    return ok(public_settings(load_settings()))


@router.post("/settings/asr/detect")
async def detect(request: Request, config: AppConfig = Depends(get_config)):
    _require_local(request, config)
    return ok(await asyncio.to_thread(detect_local))


@router.put("/settings/asr")
async def save(payload: AsrUpdate, request: Request, config: AppConfig = Depends(get_config)):
    _require_local(request, config)
    payload = merged(payload)
    try:
        # Allow turning off a broken or unavailable environment.
        if payload.enabled:
            validate_settings(payload)
        save_settings(payload)
    except (ValueError, OSError) as exc:
        raise ApiError(ErrorCode.VALIDATION_ERROR, str(exc)) from exc
    dispatcher = getattr(request.app.state, "asr_dispatcher", None)
    if dispatcher:
        dispatcher.wake.set()
    return ok(public_settings(payload), message="转写设置已保存")


@router.post("/settings/asr/test")
async def test(payload: AsrUpdate, request: Request, config: AppConfig = Depends(get_config)):
    _require_local(request, config)
    payload = merged(payload)
    try:
        validate_settings(payload)
        if payload.mode in ("local_qwen", "local_whisper"):
            def probe():
                code = ('import json,ctranslate2,faster_whisper;print(json.dumps({"gpu":ctranslate2.get_cuda_device_count()>0}))' if payload.mode=='local_whisper' else 'import json,torch,qwen_asr; print(json.dumps({"torch":torch.__version__,"gpu":torch.cuda.is_available()}))')
                proc = subprocess.run([payload.python_path, "-c", code], capture_output=True, timeout=60,
                                      creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                if proc.returncode:
                    raise ValueError(proc.stderr.decode("utf-8", errors="replace")[-1500:])
                return json.loads(proc.stdout.decode("utf-8").strip().splitlines()[-1])
            detail = await asyncio.to_thread(probe)
            return ok({"message": f"识别环境可用，GPU {'可用' if detail['gpu'] else '不可用，将使用 CPU'}。此检测未执行完整音频转写。", "detail": detail})
        headers = {"Authorization": f"Bearer {payload.api_key}"} if payload.api_key else {}
        async with httpx.AsyncClient(timeout=20, trust_env=False) as client:
            response = await client.get(payload.base_url.rstrip("/") + "/models", headers=headers)
            if response.status_code != 200:
                raise ValueError(f"服务模型列表返回 HTTP {response.status_code}，尚不能确认可用")
            models = [x["id"] for x in response.json().get("data", [])]
            if payload.model not in models:
                raise ValueError("服务可达，但模型列表中没有所填模型名")
        return ok({"message": "服务可达且模型存在；实际转写还需音频验证。"})
    except (ValueError, OSError, subprocess.TimeoutExpired, httpx.HTTPError) as exc:
        # httpx errors can include URLs; never return authorization headers.
        raise ApiError(ErrorCode.VALIDATION_ERROR, str(exc).replace(payload.api_key, "***") if payload.api_key else str(exc)) from exc


@router.get("/asr/jobs")
async def jobs(show_all: bool = Query(False, alias="all"), session: AsyncSession = Depends(get_db)):
    statement = select(AsrJob).where(AsrJob.status != "deleted").order_by(AsrJob.created_at.desc(), AsrJob.id.desc())
    if not show_all:
        statement = statement.limit(100)
    rows = (await session.scalars(statement)).all()
    return ok([job_dict(x) for x in rows])


def task_dispatcher(request):
    dispatcher = getattr(request.app.state, "asr_dispatcher", None)
    if dispatcher is None:
        raise ApiError(ErrorCode.CONFLICT, "转写队列尚未就绪，请稍后重试")
    return dispatcher


async def get_task(session, ident):
    job = await session.get(AsrJob, ident)
    if not job or job.status == "deleted":
        raise ApiError(ErrorCode.NOT_FOUND, "转写任务不存在或已删除")
    return job


@router.post("/asr/jobs/{ident}/retry")
async def retry(ident: str, request: Request, session: AsyncSession = Depends(get_db)):
    dispatcher = task_dispatcher(request)
    async with dispatcher.mutations:
        job = await get_task(session, ident)
        if job.status not in ("failed", "incomplete", "cancelled"):
            raise ApiError(ErrorCode.CONFLICT, "只能重试失败、不完整或已取消的任务")
        if (job.result or {}).get("source_deleted"):
            raise ApiError(ErrorCode.CONFLICT, "电脑源录音已删除，无法重试")
        if not load_settings().enabled:
            raise ApiError(ErrorCode.VALIDATION_ERROR, "请先在电脑设置中开启自动转写")
        if job.status == "incomplete":
            job.run_generation += 1
            job.error = "继续不完整转写"
        else:
            job.error = ""
        job.status, job.finished_at = "queued", None
        await session.commit()
        dispatcher.wake.set()
    return ok(job_dict(job))


@router.post("/asr/jobs/{ident}/cancel")
async def cancel(ident: str, request: Request, session: AsyncSession = Depends(get_db)):
    dispatcher = task_dispatcher(request)
    async with dispatcher.mutations:
        job = await get_task(session, ident)
        if job.status in ("cancelled", "cancelling"):
            return ok(job_dict(job))
        if job.status not in ("queued", "running"):
            raise ApiError(ErrorCode.CONFLICT, "任务已结束，无法取消")
        if job.status == "running":
            control = dispatcher.active.get(ident)
            if control is None:
                raise ApiError(ErrorCode.CONFLICT, "任务状态正在恢复，请刷新后重试")
            if not control.request_cancel():
                raise ApiError(ErrorCode.CONFLICT, "转写已进入归档保存阶段，无法取消，请等待完成")
            job.status, job.error = "cancelling", "正在停止转写，源录音保留"
        else:
            job.status, job.error, job.finished_at = "cancelled", "已取消转写，源录音保留", datetime.now()
            rec = await session.get(Recording, job.recording_id)
            if rec and rec.file_path == job.source_path:
                rec.transcription_status = "pending"
        await session.commit()
    return ok(job_dict(job))


@router.delete("/asr/jobs/{ident}")
async def delete(ident: str, request: Request, session: AsyncSession = Depends(get_db)):
    dispatcher = task_dispatcher(request)
    async with dispatcher.mutations:
        job = await session.get(AsrJob, ident)
        if not job:
            raise ApiError(ErrorCode.NOT_FOUND, "转写任务不存在")
        if job.status == "deleted":
            return ok({"id": ident, "status": "deleted"})
        if job.status not in ("failed", "incomplete", "completed", "cancelled") or ident in dispatcher.active:
            raise ApiError(ErrorCode.CONFLICT, "请先取消任务并等待停止，再删除任务记录")
        # Keep a receipt/tombstone so duplicate upload completion cannot requeue it.
        job.status = "deleted"
        await session.commit()
    return ok({"id": ident, "status": "deleted"}, message="任务记录已删除；录音和转写文件保留")


@router.delete("/asr/jobs/{ident}/recording")
async def delete_recording(ident: str, request: Request, session: AsyncSession = Depends(get_db)):
    dispatcher = task_dispatcher(request)
    async with dispatcher.mutations:
        job = await get_task(session, ident)
        if job.status not in ("failed", "incomplete", "cancelled") or ident in dispatcher.active:
            raise ApiError(ErrorCode.CONFLICT, "只能删除失败、不完整或已取消任务的电脑源录音")
        active = (await session.scalars(select(AsrJob).where(
            AsrJob.recording_id == job.recording_id,
            AsrJob.status.in_(("queued", "running", "cancelling"))))).first()
        if active:
            raise ApiError(ErrorCode.CONFLICT, "这条录音仍有待处理或运行中的转写任务，请先取消")
        rec = await session.get(Recording, job.recording_id)
        if not rec or not rec.file_path or Path(rec.file_path).resolve() != Path(job.source_path).resolve():
            raise ApiError(ErrorCode.CONFLICT, "录音路径已变化，未删除文件")
        from app.services.upload_progress import active_uploads
        upload = active_uploads.get(job.recording_id, {})
        if upload.get("phase") in ("receiving", "saving", "waiting_connection"):
            raise ApiError(ErrorCode.CONFLICT, "录音仍在上传，请等待上传结束后重试")
        try:
            removed = await asyncio.to_thread(delete_verified_audio, Path(job.source_path),
                get_config().resolved_recordings_root, job.source_sha256, job.source_size, job.source_mtime)
        except (OSError, ValueError) as exc:
            raise ApiError(ErrorCode.CONFLICT, str(exc)) from exc
        # Keep file_path/size/uploaded reception receipts for older phones.
        rec.deleted_at = datetime.now()
        job.result = {**(job.result or {}), "source_deleted": True, "manual_recording_deleted": True,
                      "source_note": "已手动删除电脑录音" if removed else "电脑源录音已不存在"}
        await session.commit()
    return ok(job_dict(job), message="电脑源录音已删除；已有转写文件保留")
