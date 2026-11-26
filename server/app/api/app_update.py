"""应用内热更新与版本管理 API 路由。"""

from __future__ import annotations

from pathlib import Path
from fastapi import APIRouter
from fastapi.responses import FileResponse
from app.errors import ApiError, ErrorCode
from app.schemas.common import ok

__all__ = ["router"]

router = APIRouter(tags=["app_update"])

CURRENT_APP_VERSION = "1.0.7"
CURRENT_APP_VERSION_CODE = 48
RELEASE_NOTES = (
    "1. 笔记列表默认按标题/文件名中的时间顺序排列（最新在前），并支持一键切换「最新优先 / 从早到晚」且记住选择，无日期笔记自动排末尾\n"
    "2. 阅读器原生支持 Obsidian ![[图片]]（含 |宽度）与标准 ![](...) 图片渲染，支持点击全屏放大缩放、平移与加载失败重试\n"
    "3. 课堂笔记离线同步链路支持同步图片附件（.png/.jpg/.jpeg/.webp/.gif，含 _图 目录），手机离线也能正常看图且不混入笔记列表"
)

APK_PATH = Path(__file__).resolve().parent.parent.parent.parent / "课堂学习助手.apk"


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
        filename="Remember_latest.apk",
        media_type="application/vnd.android.package-archive",
    )
