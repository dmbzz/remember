"""设置 / Provider 相关 DTO（脱敏）。"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

from app.config import AppConfig
from app.schemas.common import StrictRequestModel

__all__ = [
    "ProviderConfigDTO",
    "ProviderConfigUpdate",
    "ProviderInfo",
    "ProviderListResponse",
    "from_app_config",
]


class ProviderConfigDTO(BaseModel):
    """对外可见的配置快照（**脱敏**：密钥只显示是否已配置）。"""

    deployment_mode: Literal["local", "cloud"]
    transcription_provider: str
    llm_provider: str
    vision_provider: str
    storage_backend: str
    obsidian_root: str
    textbook_root: str
    handoff_dir: str
    auth_enabled: bool
    auth_token_set: bool
    force_https: bool
    version: str


class ProviderConfigUpdate(StrictRequestModel):
    """可在线更新的配置子集（PUT /api/settings）。"""

    transcription_provider: str | None = None
    llm_provider: str | None = None
    vision_provider: str | None = None
    obsidian_root: str | None = None
    textbook_root: str | None = None
    persist: bool = True


class ProviderInfo(BaseModel):
    """单个 Provider 的可用性与能力描述。"""

    name: str
    kind: str
    available: bool
    runs_offline: bool = False
    incurs_cost: bool = False
    description: str = ""
    error: str | None = None


class ProviderListResponse(BaseModel):
    """四类 Provider 的可用列表。"""

    transcription: list[ProviderInfo] = Field(default_factory=list)
    llm: list[ProviderInfo] = Field(default_factory=list)
    vision: list[ProviderInfo] = Field(default_factory=list)
    storage: list[ProviderInfo] = Field(default_factory=list)
    active: dict[str, Any] = Field(default_factory=dict)


def from_app_config(config: AppConfig) -> ProviderConfigDTO:
    """由 ``AppConfig`` 生成脱敏配置 DTO。"""
    return ProviderConfigDTO(
        deployment_mode=config.deployment_mode,
        transcription_provider=config.transcription_provider,
        llm_provider=config.llm_provider,
        vision_provider=config.vision_provider,
        storage_backend=config.storage_backend,
        obsidian_root=config.obsidian_root,
        textbook_root=config.textbook_root,
        handoff_dir=str(config.resolved_handoff_dir),
        auth_enabled=config.auth_enabled,
        auth_token_set=bool(config.auth_token),
        force_https=config.force_https,
        version=config.version,
    )
