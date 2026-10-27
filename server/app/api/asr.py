"""ASR setup is editable only on the Windows loopback interface."""
import asyncio
import json
import os
import subprocess
from pathlib import Path

import httpx
from fastapi import APIRouter, Depends, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.settings import _require_local
from app.config import AppConfig
from app.deps import get_config, get_db
from app.db.models import AsrJob
from app.errors import ApiError, ErrorCode
from app.schemas.common import ok
from app.services.asr_jobs import job_dict
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
        if payload.mode == "local_qwen":
            def probe():
                code = 'import json,torch,qwen_asr; print(json.dumps({"torch":torch.__version__,"gpu":torch.cuda.is_available()}))'
                proc = subprocess.run([payload.python_path, "-c", code], capture_output=True, timeout=60,
                                      creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                if proc.returncode:
                    raise ValueError(proc.stderr.decode("utf-8", errors="replace")[-1500:])
                return json.loads(proc.stdout.decode("utf-8").strip().splitlines()[-1])
            detail = await asyncio.to_thread(probe)
            return ok({"message": f"Qwen 环境可用，GPU {'可用' if detail['gpu'] else '不可用，将使用 CPU'}。此检测未执行完整音频转写。", "detail": detail})
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
async def jobs(session: AsyncSession = Depends(get_db)):
    rows = (await session.scalars(select(AsrJob).order_by(AsrJob.created_at.desc()).limit(100))).all()
    return ok([job_dict(x) for x in rows])


@router.post("/asr/jobs/{ident}/retry")
async def retry(ident: str, request: Request, session: AsyncSession = Depends(get_db)):
    job = await session.get(AsrJob, ident)
    if not job:
        raise ApiError(ErrorCode.NOT_FOUND, "转写任务不存在")
    if job.status not in ("failed", "incomplete"):
        raise ApiError(ErrorCode.VALIDATION_ERROR, "只能重试失败或不完整的任务")
    if not load_settings().enabled:
        raise ApiError(ErrorCode.VALIDATION_ERROR, "请先在电脑设置中开启自动转写")
    # Only remove generated inference receipts for a deliberate INCOMPLETE retry.
    # Completed historical TXT files and user ledger entries are preserved.
    dispatcher = getattr(request.app.state, "asr_dispatcher", None)
    if job.status == "incomplete":
        # New work/output generation preserves the previous incomplete TXT.
        job.run_generation += 1
        job.error = "继续不完整转写"
    job.status = "queued"
    await session.commit()
    if dispatcher:
        dispatcher.wake.set()
    return ok(job_dict(job))
