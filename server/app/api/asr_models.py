"""The model installer and audio tests are available on the receiving PC only."""
from pathlib import Path
from typing import Literal
import uuid

from fastapi import APIRouter, Depends, File, Form, Query, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.settings import _require_local
from app.config import AppConfig
from app.deps import get_config, get_db
from app.db.models import AsrJob
from app.errors import ApiError, ErrorCode
from app.schemas.common import StrictRequestModel, ok
from app.services.asr_model_manager import get_model_manager
from app.services.asr_settings import public_settings

router=APIRouter(tags=['asr-models'])

class InstallRequest(StrictRequestModel):
    model_id: str
    channel: Literal['auto','modelscope','huggingface','hf_mirror']='auto'
    device: Literal['auto','cpu']='auto'

class DeploymentRequest(StrictRequestModel):
    deployment_id: str

def failure(error):
    return ApiError(ErrorCode.VALIDATION_ERROR,str(error))

@router.get('/asr/models')
async def catalog(request:Request,refresh:bool=False,config:AppConfig=Depends(get_config)):
    _require_local(request,config)
    return ok(await run_in_threadpool(get_model_manager().catalog,refresh))

@router.get('/asr/models/operation')
async def operation(request:Request,config:AppConfig=Depends(get_config)):
    _require_local(request,config)
    return ok(get_model_manager().snapshot())

@router.post('/asr/models/install')
async def install(payload:InstallRequest,request:Request,config:AppConfig=Depends(get_config)):
    _require_local(request,config)
    try:
        return ok(await run_in_threadpool(get_model_manager().install,payload.model_id,payload.channel,payload.device))
    except (ValueError,OSError) as error: raise failure(error) from error

@router.post('/asr/models/cancel')
async def cancel(request:Request,config:AppConfig=Depends(get_config)):
    _require_local(request,config)
    return ok(get_model_manager().cancel())

@router.post('/asr/models/test')
async def test_sample(payload:DeploymentRequest,request:Request,config:AppConfig=Depends(get_config)):
    _require_local(request,config)
    try:
        return ok(get_model_manager().test(payload.deployment_id))
    except (ValueError,OSError) as error: raise failure(error) from error

@router.post('/asr/models/test-audio')
async def test_audio(request:Request,deployment_id:str=Form(...),reference:str=Form(''),
                     file:UploadFile=File(...),config:AppConfig=Depends(get_config)):
    _require_local(request,config)
    if len(reference)>10000: raise failure(ValueError('参考文字过长'))
    suffix=Path(file.filename or '').suffix.lower()
    if suffix not in ('.wav','.mp3','.m4a','.aac','.flac','.ogg','.opus','.wma'):
        raise failure(ValueError('请选择 WAV、MP3、M4A 等音频文件'))
    content=await file.read(20*1024*1024+1)
    if not content or len(content)>20*1024*1024: raise failure(ValueError('测试文件需为 1 字节至 20MB，且不超过60秒'))
    manager=get_model_manager()
    source=manager.path('test-inputs',uuid.uuid4().hex+suffix)
    source.parent.mkdir(parents=True,exist_ok=True)
    source.write_bytes(content)
    try:
        return ok(manager.test(deployment_id,source,reference))
    except (ValueError,OSError) as error:
        source.unlink(missing_ok=True)
        raise failure(error) from error

@router.post('/asr/models/activate')
async def activate(payload:DeploymentRequest,request:Request,config:AppConfig=Depends(get_config),session:AsyncSession=Depends(get_db)):
    _require_local(request,config)
    if (await session.scalars(select(AsrJob).where(AsrJob.status=='running').limit(1))).first():
        raise ApiError(ErrorCode.CONFLICT,'正在转写，请等待当前任务结束后再使用新模型')
    try:
        return ok(public_settings(await run_in_threadpool(get_model_manager().activate,payload.deployment_id)))
    except (ValueError,OSError) as error: raise failure(error) from error
