"""结构化日志初始化（架构设计 §7.3）。

约定：
    - 结构化 JSON；字段固定 ``ts`` / ``level`` / ``logger`` / ``request_id`` / ``module`` / ``msg``。
    - 中间件生成 ``request_id`` 并回写响应头 ``X-Request-Id``，贯穿任务队列。
    - **禁止 print**（CLI 脚本除外）；日志不得写入音频/教材原文、Token、API Key（脱敏）。
"""

from __future__ import annotations

import logging
import sys
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

import structlog
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

__all__ = ["setup_logging", "get_logger", "RequestIdMiddleware", "REQUEST_ID_HEADER"]

REQUEST_ID_HEADER = "X-Request-Id"

# 敏感字段名（命中即脱敏）
_SENSITIVE_KEYS = {
    "api_key",
    "apikey",
    "token",
    "auth_token",
    "authorization",
    "secret",
    "secret_key",
    "access_key",
    "password",
}


def _mask_sensitive(
    _logger: Any, _method: str, event_dict: dict[str, Any]
) -> dict[str, Any]:
    """structlog 处理器：对敏感字段脱敏。"""
    for key in list(event_dict.keys()):
        if key.lower() in _SENSITIVE_KEYS and event_dict[key]:
            event_dict[key] = "***"
    return event_dict


def setup_logging(level: str = "INFO", fmt: str = "json") -> None:
    """初始化 structlog 与标准 logging。

    :param level: 日志级别（DEBUG/INFO/WARNING/ERROR）
    :param fmt: ``json``（生产）或 ``console``（本地可读）
    """
    log_level = getattr(logging, level.upper(), logging.INFO)

    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=log_level,
        force=True,
    )

    shared_processors: list[Any] = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True, key="ts"),
        _mask_sensitive,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
    ]

    if fmt == "console":
        renderer: Any = structlog.dev.ConsoleRenderer(colors=False)
    else:
        renderer = structlog.processors.JSONRenderer(ensure_ascii=False)

    structlog.configure(
        processors=[*shared_processors, renderer],
        wrapper_class=structlog.make_filtering_bound_logger(log_level),
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str) -> structlog.stdlib.BoundLogger:
    """获取结构化 logger。"""
    return structlog.get_logger(name)


class RequestIdMiddleware(BaseHTTPMiddleware):
    """为每个请求生成/透传 ``request_id``，写入日志上下文与响应头。"""

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        request_id = request.headers.get(REQUEST_ID_HEADER) or uuid.uuid4().hex
        request.state.request_id = request_id

        structlog.contextvars.clear_contextvars()
        structlog.contextvars.bind_contextvars(
            request_id=request_id,
            method=request.method,
            path=request.url.path,
        )
        try:
            response = await call_next(request)
        finally:
            structlog.contextvars.clear_contextvars()

        response.headers[REQUEST_ID_HEADER] = request_id
        return response
