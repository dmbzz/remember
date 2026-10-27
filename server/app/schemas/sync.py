"""笔记多端同步 DTO（FR-31 / ADR-006 / ADR-008）。

请求模型继承 StrictRequestModel（extra='forbid'）；响应模型使用 BaseModel。
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "SyncPushRequest",
    "SyncPullRequest",
    "SyncPullResponse",
    "SyncStateDTO",
    "SyncManifestItem",
    "SyncManifestResponse",
    "AnnotationPushRequest",
    "AnnotationDTO",
    "AnnotationListResponse",
    "ConflictResolveRequest",
]


# ---------------------------------------------------------------------------
# 同步清单（manifest）—— 客户端先问服务端「你有哪些笔记、各自什么 hash」
# ---------------------------------------------------------------------------

class SyncManifestItem(BaseModel):
    """清单条目：一篇笔记在服务端的同步状态快照。"""

    note_id: str
    content_hash: str | None = None
    updated_at: datetime
    origin: str = "win"
    deleted: bool = False


class SyncManifestResponse(BaseModel):
    """同步清单响应。"""

    items: list[SyncManifestItem] = Field(default_factory=list)
    total: int = 0
    server_time: datetime


# ---------------------------------------------------------------------------
# 推送（客户端 → 服务端）
# ---------------------------------------------------------------------------

class SyncPushRequest(StrictRequestModel):
    """客户端向服务端推送笔记正文（Win 上行 / 云端覆写）。

    语义：「我这边的笔记内容如下，请协调写入」。
    """

    note_id: str = Field(..., description="稳定逻辑身份（uuid）")
    content_hash: str = Field(..., description="sha256(markdown 正文字节)")
    markdown: str = Field(..., description="笔记 Markdown 全文")
    origin: Literal["win", "cloud"] = Field(
        default="win", description="变更来源端"
    )
    base_hash: str | None = Field(
        default=None,
        description="推送者上次已知的服务端 hash（用于乐观并发检测）",
    )


# ---------------------------------------------------------------------------
# 拉取（服务端 → 客户端）
# ---------------------------------------------------------------------------

class SyncPullRequest(StrictRequestModel):
    """客户端向服务端拉取笔记正文。"""

    note_id: str = Field(..., description="稳定逻辑身份")
    known_hash: str | None = Field(
        default=None,
        description="客户端当前持有的 hash；若与服务端一致则返回 304 语义（无变更）",
    )


class SyncPullResponse(BaseModel):
    """拉取响应。"""

    note_id: str
    content_hash: str | None = None
    markdown: str | None = None
    updated_at: datetime | None = None
    origin: str = "win"
    deleted: bool = False
    changed: bool = True  # False 表示与 known_hash 一致，无需更新


# ---------------------------------------------------------------------------
# 同步状态 DTO
# ---------------------------------------------------------------------------

class SyncStateDTO(BaseModel):
    """单篇笔记的三方同步状态。"""

    note_id: str
    win_version: int = 0
    win_hash: str | None = None
    cloud_version: int = 0
    cloud_hash: str | None = None
    android_version: int = 0
    android_hash: str | None = None
    last_synced_at: datetime | None = None
    conflict: bool = False
    conflict_refs: list[Any] = Field(default_factory=list)
    updated_at: datetime | None = None


# ---------------------------------------------------------------------------
# 批注（Android → 云端 → Win 单向上行）
# ---------------------------------------------------------------------------

class AnnotationPushRequest(StrictRequestModel):
    """Android 端推送批注到服务端。

    批注独立存储，不修改笔记正文（ADR-006 ⑥）。
    用 note_id 关联（不用文件路径——笔记改名/移动不断链）。
    """

    note_id: str = Field(..., description="关联笔记的稳定 note_id")
    annotations: list[dict[str, Any]] = Field(
        ...,
        description=(
            "批注列表，每条含 {id, type, anchor, content, created_at}；"
            "anchor 为笔记正文中的锚点标识（如行号或关键词片段）"
        ),
    )
    origin: Literal["android"] = Field(
        default="android", description="批注来源（固定 android）"
    )


class AnnotationDTO(BaseModel):
    """单条批注。"""

    id: str
    note_id: str
    type: str = "highlight"  # highlight / comment / bookmark
    anchor: str = ""
    content: str = ""
    origin: str = "android"
    created_at: datetime | None = None


class AnnotationListResponse(BaseModel):
    """批注列表响应。"""

    note_id: str
    annotations: list[AnnotationDTO] = Field(default_factory=list)
    total: int = 0


# ---------------------------------------------------------------------------
# 冲突裁决
# ---------------------------------------------------------------------------

class ConflictResolveRequest(StrictRequestModel):
    """用户裁决冲突：keep_remote / keep_local / keep_both。"""

    note_id: str = Field(..., description="冲突笔记的 note_id")
    resolution: Literal["keep_remote", "keep_local", "keep_both"] = Field(
        ..., description="冲突裁决策略"
    )
