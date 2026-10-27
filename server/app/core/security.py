"""Bearer Token 鉴权（架构设计 §1.4、§7、FR-18）。

- 本地模式：``auth_enabled=false`` → 中间件不挂载。
- 云端模式：``auth_enabled=true`` → 除 ``/api/health`` 外所有接口需 ``Authorization: Bearer <token>``。
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
import ipaddress
import hmac

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from app.errors import ErrorCode, error_response_body
from app.services.pairing_service import PairingService

__all__ = ["AuthMiddleware", "LanPairingMiddleware", "EXEMPT_PATHS", "is_loopback_client"]

# 免鉴权路径（健康检查必须可匿名访问）
EXEMPT_PATHS: frozenset[str] = frozenset({"/api/health", "/docs", "/openapi.json", "/redoc"})


def is_loopback_client(host: str | None) -> bool:
    try:
        return ipaddress.ip_address(host or "").is_loopback
    except ValueError:
        return False


class LanPairingMiddleware(BaseHTTPMiddleware):
    """本机免配对；局域网设备除健康与配对接口外均需设备令牌。"""

    def __init__(self, app, pairing: PairingService) -> None:  # noqa: ANN001
        super().__init__(app)
        self._pairing = pairing

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        host = request.client.host if request.client else None
        path = request.url.path
        loopback = is_loopback_client(host)

        if path in {"/api/pairing/info", "/api/pairing/revoke-all"} and not loopback:
            return JSONResponse(
                status_code=403,
                content=error_response_body(ErrorCode.UNAUTHORIZED, "该操作只能在电脑本机执行"),
            )
        if loopback or path in {"/api/health", "/api/pairing/exchange"}:
            return await call_next(request)

        scheme, _, token = request.headers.get("Authorization", "").partition(" ")
        if not hmac.compare_digest(scheme.lower(), "bearer") or not self._pairing.valid_token(token):
            return JSONResponse(
                status_code=401,
                content=error_response_body(ErrorCode.UNAUTHORIZED, "手机尚未配对或配对已失效"),
            )
        return await call_next(request)


class AuthMiddleware(BaseHTTPMiddleware):
    """静态 Bearer Token 校验中间件。"""

    def __init__(self, app, auth_token: str | None = None) -> None:  # noqa: ANN001
        super().__init__(app)
        self._expected_token = auth_token or ""

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        path = request.url.path
        if path in EXEMPT_PATHS or request.method == "OPTIONS":
            return await call_next(request)

        header = request.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "bearer" or not token:
            return self._unauthorized("缺少或格式错误的 Authorization 头")
        if not self._expected_token:
            return self._unauthorized("服务端未配置鉴权 Token")
        if token != self._expected_token:
            return self._unauthorized("Token 无效")
        return await call_next(request)

    @staticmethod
    def _unauthorized(message: str) -> JSONResponse:
        return JSONResponse(
            status_code=401,
            content=error_response_body(ErrorCode.UNAUTHORIZED, message),
        )
