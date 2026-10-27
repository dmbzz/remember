"""应用内热更新与版本管理 API 路由。"""

from __future__ import annotations

from pathlib import Path
from fastapi import APIRouter
from fastapi.responses import FileResponse
from app.errors import ApiError, ErrorCode
from app.schemas.common import ok

__all__ = ["router"]

router = APIRouter(tags=["app_update"])

CURRENT_APP_VERSION = "0.1.37"
CURRENT_APP_VERSION_CODE = 38
RELEASE_NOTES = (
    "1. 正式更名 remember，统一采用复习折页品牌图标\n"
    "2. 更新启动器、窗口、通知、小组件及网页品牌，保留笔记、录音和配对数据"
)

APK_PATH = Path(__file__).resolve().parent.parent.parent.parent / "remember.apk"


@router.get("/app/version", summary="检查移动端最新版本")
async def check_app_version(current_code: int = 1) -> dict:
    """检查是否有更新版本，提供应用内免重新查找下载的直接更新流。"""
    has_update = CURRENT_APP_VERSION_CODE > current_code
    return ok({
        "version": CURRENT_APP_VERSION,
        "version_code": CURRENT_APP_VERSION_CODE,
        "release_notes": RELEASE_NOTES,
        "download_url": "/api/app/download",
        "has_update": has_update,
        "force_update": False,
        "file_size_bytes": APK_PATH.stat().st_size if APK_PATH.exists() else 0,
    })


@router.get("/app/download", summary="下载移动端最新安装包")
async def download_app_apk():
    """直接流式传输最新安装包，用于应用内无感更新下载。"""
    if not APK_PATH.exists():
        raise ApiError(ErrorCode.NOT_FOUND, "未找到最新 APK 安装包，请先执行构建")
    return FileResponse(
        path=str(APK_PATH),
        filename="remember_latest.apk",
        media_type="application/vnd.android.package-archive",
    )
