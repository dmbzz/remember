"""电脑本机显示连接码，手机用连接码取得局域网访问令牌。"""

from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import Field

from app.config import get_app_config
from app.errors import ApiError, ErrorCode, error_response_body
from app.schemas.common import StrictRequestModel, ok
from app.services.pairing_service import PairingError, PairingService

router = APIRouter(prefix="/pairing", tags=["pairing"])


class ResolveRequest(StrictRequestModel):
    code: str = Field(pattern=r"^[0-9]{6}$")
    server_id: str | None = Field(default=None, pattern=r"^[0-9a-f]{16}$")


class ExchangeRequest(ResolveRequest):
    device_name: str = Field(default="Android 手机", min_length=1, max_length=64)


def _service(request: Request) -> PairingService:
    if get_app_config().deployment_mode != "local":
        raise ApiError(ErrorCode.NOT_FOUND, "云端模式不提供局域网配对")
    return request.app.state.pairing_service


@router.get("/info", summary="电脑本机查看连接码")
async def pairing_info(request: Request) -> dict:
    return ok(_service(request).info())


@router.get("/identity", summary="匿名确认电脑公开身份")
async def identity(request: Request) -> dict:
    return ok(_service(request).public_identity())


@router.post("/exchange", summary="手机用连接码配对")
async def exchange(payload: ExchangeRequest, request: Request) -> dict:
    try:
        token = _service(request).exchange(
            code=payload.code,
            device_name=payload.device_name,
            client_host=request.client.host if request.client else "unknown",
            server_id=payload.server_id,
        )
    except PairingError as exc:
        return JSONResponse(
            status_code=exc.status_code,
            content=error_response_body(ErrorCode.UNAUTHORIZED, str(exc)),
        )
    return ok({"token": token, "device_name": payload.device_name})


@router.post("/resolve", summary="验证短连接码并确认电脑身份")
async def resolve(payload: ResolveRequest, request: Request) -> dict:
    try:
        identity = _service(request).resolve(
            code=payload.code,
            client_host=request.client.host if request.client else "unknown",
            server_id=payload.server_id,
        )
    except PairingError as exc:
        return JSONResponse(
            status_code=exc.status_code,
            content=error_response_body(ErrorCode.UNAUTHORIZED, str(exc)),
        )
    return ok(identity)


@router.post("/revoke-all", summary="电脑本机撤销所有手机连接")
async def revoke_all(request: Request) -> dict:
    _service(request).revoke_all()
    return ok({"revoked": True})


@router.get("/check", summary="检查手机连接状态")
async def check_pairing(request: Request) -> dict:
    _service(request)
    return ok({"connected": True})
