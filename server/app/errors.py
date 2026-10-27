"""统一错误码 + 异常类型 + FastAPI 异常处理器（架构设计 §7.2）。

错误码段位：
    1xxx 配置 / Provider
    2xxx 课表
    3xxx 录音 / 上传
    4xxx 转写
    5xxx 笔记 / 归档
    6xxx 教材 / 课件
    7xxx 作业
    8xxx 交接 / 索引 / 用量
"""

from __future__ import annotations

from enum import IntEnum
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

__all__ = [
    "ErrorCode",
    "ApiError",
    "ProviderError",
    "http_status_for",
    "error_response_body",
    "register_exception_handlers",
]


class ErrorCode(IntEnum):
    """业务错误码。``code=0`` 表示成功。"""

    OK = 0

    # 1xxx —— 配置 / Provider
    CONFIG_ERROR = 1001
    PROVIDER_NOT_FOUND = 1002
    PROVIDER_CONFIG_ERROR = 1003
    PROVIDER_CALL_FAILED = 1004
    PROVIDER_UNAVAILABLE = 1005
    # 视觉 / 多模态 OCR 专用：让调用方分清「没配置/不可用」与「调用失败」
    VISION_PROVIDER_UNAVAILABLE = 1006
    VISION_CALL_FAILED = 1007

    # 2xxx —— 课表
    SCHEDULE_ERROR = 2001

    # 3xxx —— 录音 / 上传
    RECORDING_ERROR = 3001
    UPLOAD_ERROR = 3002

    # 4xxx —— 转写
    TRANSCRIPTION_ERROR = 4001

    # 5xxx —— 笔记 / 归档
    NOTE_ERROR = 5001
    ARCHIVE_ERROR = 5002

    # 6xxx —— 教材 / 课件
    TEXTBOOK_ERROR = 6001
    COURSEWARE_ERROR = 6002

    # 7xxx —— 作业
    HOMEWORK_ERROR = 7001

    # 8xxx —— 交接 / 索引 / 用量
    HANDOFF_ERROR = 8001
    INDEX_ERROR = 8002
    USAGE_ERROR = 8003

    # 通用
    UNAUTHORIZED = 4010
    NOT_FOUND = 4040
    CONFLICT = 4090
    VALIDATION_ERROR = 4220
    INTERNAL_ERROR = 5000


# 错误码 → HTTP 状态码映射
_CODE_TO_HTTP: dict[int, int] = {
    ErrorCode.OK: 200,
    ErrorCode.UNAUTHORIZED: 401,
    ErrorCode.NOT_FOUND: 404,
    ErrorCode.CONFLICT: 409,
    ErrorCode.VALIDATION_ERROR: 422,
    ErrorCode.INTERNAL_ERROR: 500,
    # 视觉不可用 = 依赖服务不可用（503）；调用失败 = 上游异常（502）
    ErrorCode.VISION_PROVIDER_UNAVAILABLE: 503,
    ErrorCode.VISION_CALL_FAILED: 502,
}


def http_status_for(code: int) -> int:
    """根据业务错误码推断 HTTP 状态码。"""
    if code in _CODE_TO_HTTP:
        return _CODE_TO_HTTP[code]
    if code == ErrorCode.OK:
        return 200
    # 1xxx / 8xxx 视为服务端问题
    if 1000 <= code < 2000 or code >= 8000:
        return 500
    return 400


class ApiError(Exception):
    """业务异常：统一响应体 ``{code, data, message}`` 的载体。"""

    def __init__(
        self,
        code: int,
        message: str = "",
        *,
        http_status: int | None = None,
        data: Any = None,
    ) -> None:
        self.code = int(code)
        if not message:
            try:
                message = ErrorCode(self.code).name
            except ValueError:
                message = "未知错误"
        self.message = message
        self.http_status = http_status or http_status_for(self.code)
        self.data = data
        super().__init__(f"[{self.code}] {self.message}")


class ProviderError(Exception):
    """Provider 统一异常（架构设计 §3.3）。

    :param code: 业务错误码（默认 ``PROVIDER_CALL_FAILED``）
    :param provider: Provider 名称
    :param retryable: 是否可重试（网络/限流 → True；鉴权/格式 → False）
    """

    def __init__(
        self,
        message: str,
        *,
        provider: str = "unknown",
        code: int = ErrorCode.PROVIDER_CALL_FAILED,
        retryable: bool = False,
        data: Any = None,
    ) -> None:
        self.code = int(code)
        self.provider = provider
        self.message = message
        self.retryable = retryable
        self.data = data
        super().__init__(f"[{self.code}] provider={provider} retryable={retryable} {message}")


def error_response_body(code: int, message: str, data: Any = None) -> dict[str, Any]:
    """构造统一错误响应体。"""
    return {"code": int(code), "data": data, "message": message}


def register_exception_handlers(application: FastAPI) -> None:
    """注册全局异常处理器，保证所有错误都返回统一响应体。"""

    @application.exception_handler(ApiError)
    async def _handle_api_error(_request: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.http_status,
            content=error_response_body(exc.code, exc.message, exc.data),
        )

    @application.exception_handler(ProviderError)
    async def _handle_provider_error(_request: Request, exc: ProviderError) -> JSONResponse:
        status = 503 if exc.retryable else http_status_for(exc.code)
        return JSONResponse(
            status_code=status,
            content=error_response_body(
                exc.code,
                f"Provider[{exc.provider}] 错误：{exc.message}",
                {"provider": exc.provider, "retryable": exc.retryable},
            ),
        )

    @application.exception_handler(RequestValidationError)
    async def _handle_validation(_request: Request, exc: RequestValidationError) -> JSONResponse:
        # Validator contexts may contain ValueError instances, which JSONResponse
        # cannot serialize. Return actionable, serializable field errors.
        details = [{k:v for k,v in item.items() if k not in ('ctx','input')} for item in exc.errors()]
        message = '参数校验失败'
        if details:
            message += '：' + str(details[0]['msg']).replace('Value error, ', '')
        return JSONResponse(
            status_code=422,
            content=error_response_body(
                ErrorCode.VALIDATION_ERROR, message, details
            ),
        )

    @application.exception_handler(StarletteHTTPException)
    async def _handle_http(_request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = {401: ErrorCode.UNAUTHORIZED, 404: ErrorCode.NOT_FOUND}.get(
            int(exc.status_code), int(exc.status_code) * 10
        )
        return JSONResponse(
            status_code=exc.status_code,
            content=error_response_body(code, str(exc.detail)),
        )

    @application.exception_handler(Exception)
    async def _handle_unexpected(_request: Request, exc: Exception) -> JSONResponse:
        return JSONResponse(
            status_code=500,
            content=error_response_body(
                ErrorCode.INTERNAL_ERROR, f"服务器内部错误：{exc.__class__.__name__}"
            ),
        )
