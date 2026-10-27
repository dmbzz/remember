"""健康检查路由。"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.config import AppConfig
from app.deps import get_config
from app.schemas.common import ok

__all__ = ["router"]

router = APIRouter(tags=["health"])


@router.get("/health", summary="健康检查（返回当前运行模式）")
async def health(config: AppConfig = Depends(get_config)) -> dict:
    """返回服务状态与当前运行模式（local / cloud）。

    统一响应体包裹（架构设计 §7.2）；``data.mode`` 即当前部署形态。
    """
    return ok(
        {
            "status": "ok",
            "mode": config.deployment_mode,
            "version": config.version,
            "app": config.app_name,
            "force_https": config.force_https,
            "auth_enabled": config.auth_enabled,
        }
    )
