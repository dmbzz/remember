"""Obsidian 目录校验、状态诊断与初始化 DTO。"""

from __future__ import annotations

from pydantic import BaseModel, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "ObsidianInitRequest",
    "ObsidianInitResponse",
    "ObsidianPathStatusDTO",
    "ObsidianPathValidateRequest",
]


class ObsidianPathStatusDTO(BaseModel):
    """Obsidian 库目录的健康度与结构诊断信息。"""

    path: str
    obsidian_root: str = ""
    exists: bool = False
    is_dir: bool = False
    is_directory: bool = False
    is_writable: bool = False
    writable: bool = False
    has_obsidian_dir: bool = False
    has_notes_dir: bool = False
    has_transcripts_dir: bool = False
    has_task_planning_dir: bool = False
    has_tracking_file: bool = False
    is_fully_initialized: bool = False
    skeleton_initialized: bool = False
    error: str | None = None


class ObsidianPathValidateRequest(StrictRequestModel):
    """校验 Obsidian 路径请求。"""

    path: str = Field(..., description="待校验的本地 Obsidian 库绝对路径")


class ObsidianInitRequest(StrictRequestModel):
    """初始化 Obsidian 库目录请求。"""

    path: str | None = Field(
        default=None,
        description="目标 Obsidian 库绝对路径；若未提供则使用当前配置的 obsidian_root",
    )
    auto_switch: bool = Field(
        default=True,
        description="初始化成功后是否自动将当前服务配置切换为此路径",
    )
    persist: bool = Field(
        default=True,
        description="切换后是否持久化保存至用户配置文件（config.user.yaml）",
    )


class ObsidianInitResponse(BaseModel):
    """Obsidian 库初始化结果。"""

    path: str
    created_dirs: list[str] = Field(default_factory=list)
    initialized_files: list[str] = Field(default_factory=list)
    status: ObsidianPathStatusDTO
