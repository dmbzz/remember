"""配置系统 —— 本地 / 云端切换的**唯一入口**（架构设计 §1.4、§7.4）。

硬约定：
    - 任何模块不得自行读 YAML / env，一律经 ``get_app_config()`` 或 ``Depends(get_config)``。
    - 加载顺序（低 → 高）：代码默认值 < YAML 文件 < 环境变量（``CNA_`` 前缀）。
    - 运行模式切换：``CNA_CONFIG_FILE=config/config.cloud.yaml``
      或 ``CNA_DEPLOYMENT_MODE=cloud``（自动匹配 ``config.<mode>.yaml``）。
"""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field
from pydantic_settings import (
    BaseSettings,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
    YamlConfigSettingsSource,
)

# ---------------------------------------------------------------------------
# 路径常量（不写死数据目录；数据目录一律走配置）
# ---------------------------------------------------------------------------
SERVER_DIR: Path = Path(__file__).resolve().parent.parent  # .../server
CONFIG_DIR: Path = SERVER_DIR / "config"
PROJECT_ROOT: Path = SERVER_DIR.parent  # .../class_notes_assistant
USER_CONFIG_FILE: Path = CONFIG_DIR / "config.user.yaml"

DeploymentMode = Literal["local", "cloud"]
TranscriptionProviderName = Literal["local_gpu", "cloud_api", "on_device"]
StorageBackendName = Literal["local_fs", "object_store"]


def resolve_config_file() -> Path:
    """按环境变量解析配置文件的绝对路径。

    优先级：
        1. ``CNA_CONFIG_FILE``（相对路径基于 ``server/`` 解析）
        2. ``CNA_DEPLOYMENT_MODE`` → ``config/config.<mode>.yaml``
        3. 兜底 ``config/config.local.yaml``
    """
    explicit = os.environ.get("CNA_CONFIG_FILE", "").strip()
    if explicit:
        candidate = Path(explicit)
        return candidate if candidate.is_absolute() else (SERVER_DIR / candidate)

    mode = os.environ.get("CNA_DEPLOYMENT_MODE", "local").strip() or "local"
    candidate = CONFIG_DIR / f"config.{mode}.yaml"
    if candidate.exists():
        return candidate
    return CONFIG_DIR / "config.local.yaml"


class ProviderConnectionConfig(BaseModel):
    """单个 Provider 的连接/参数配置（字段宽松，按 provider 取用）。"""

    model_config = ConfigDict(extra="allow")

    base_url: str | None = None
    api_key: str | None = None
    model: str | None = None
    model_name: str | None = None
    device: str | None = None
    compute_type: str | None = None
    language: str | None = None
    beam_size: int | None = None
    vad_filter: bool | None = None
    endpoint: str | None = None
    bucket: str | None = None
    access_key: str | None = None
    secret_key: str | None = None
    region: str | None = None
    prefix: str | None = None
    timeout: float | None = None
    max_retries: int | None = None
    unit_price_per_hour: float | None = None

    def as_dict(self) -> dict[str, Any]:
        """返回非空字段字典（供 Provider 读取参数）。"""
        return self.model_dump(exclude_none=True)


class SyncConfig(BaseModel):
    """笔记多端同步配置（FR-31/FR-32，架构设计 §3.1 ProviderConfig.sync）。

    - ``enabled``：是否启用同步。
    - ``endpoint``：同步服务端地址（客户端用；服务端自身为空）。
    - ``scope``：同步范围，固定 ``notes_markdown``（只同步笔记 Markdown）。
    - ``conflict_policy``：冲突策略，默认 ``keep_both``（保留两份，绝不静默覆盖）。
    - ``interval_seconds``：Windows 端定时轮询间隔（默认 300s = 5 分钟）。
    """

    model_config = ConfigDict(extra="allow")

    enabled: bool = True
    endpoint: str | None = None
    scope: Literal["notes_markdown"] = "notes_markdown"
    conflict_policy: Literal["keep_both", "keep_remote", "keep_local"] = "keep_both"
    interval_seconds: int = 300


class ProvidersConfig(BaseModel):
    """所有 Provider 的参数容器（与 YAML ``providers:`` 段一一对应）。"""

    model_config = ConfigDict(extra="allow")

    local_gpu: ProviderConnectionConfig = Field(default_factory=ProviderConnectionConfig)
    cloud_asr: ProviderConnectionConfig = Field(default_factory=ProviderConnectionConfig)
    on_device: ProviderConnectionConfig = Field(default_factory=ProviderConnectionConfig)
    cloud_llm: ProviderConnectionConfig = Field(default_factory=ProviderConnectionConfig)
    local_llm: ProviderConnectionConfig = Field(default_factory=ProviderConnectionConfig)
    cloud_vision: ProviderConnectionConfig = Field(default_factory=ProviderConnectionConfig)
    local_vision: ProviderConnectionConfig = Field(default_factory=ProviderConnectionConfig)
    object_store: ProviderConnectionConfig = Field(default_factory=ProviderConnectionConfig)

    # Provider 名称（对外）→ settings 键（YAML providers 段）的映射
    _NAME_TO_KEY: dict[str, str] = {
        "local_gpu": "local_gpu",
        "cloud_api": "cloud_asr",
        "on_device": "on_device",
        "cloud_llm": "cloud_llm",
        "local_llm": "local_llm",
        "cloud_vision": "cloud_vision",
        "local_vision": "local_vision",
        "object_store": "object_store",
    }

    def for_provider(self, provider_name: str) -> ProviderConnectionConfig:
        """按对外 Provider 名取参数；未知名称返回空配置。"""
        key = self._NAME_TO_KEY.get(provider_name, provider_name)
        value = getattr(self, key, None)
        if isinstance(value, ProviderConnectionConfig):
            return value
        return ProviderConnectionConfig()


class AppConfig(BaseSettings):
    """应用总配置 —— 本地/云端两种形态的单一开关。"""

    model_config = SettingsConfigDict(
        env_prefix="CNA_",
        env_file=str(SERVER_DIR / ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # ---- 基础 ----
    app_name: str = "class_notes_assistant"
    version: str = "0.1.0"
    deployment_mode: DeploymentMode = "local"

    # ---- 服务 ----
    host: str = "127.0.0.1"
    port: int = 8000
    log_level: str = "INFO"
    log_format: Literal["json", "console"] = "json"

    # ---- 数据层 ----
    db_url: str = "sqlite+aiosqlite:///./data/remember.db"
    db_echo: bool = False

    # ---- 存储 ----
    storage_backend: StorageBackendName = "local_fs"
    storage_root: str = "./data/storage"
    recordings_root: str | None = None

    # ---- Provider 选择 ----
    transcription_provider: TranscriptionProviderName = "local_gpu"
    llm_provider: str = "cloud_llm"
    vision_provider: str = "cloud_vision"

    # ---- 数据目录（不写死绝对路径，统一走配置）----
    obsidian_root: str = "./data/notes"
    textbook_root: str = "./data/textbooks"
    handoff_dir: str = "docs/handoff"

    # ---- 鉴权 / 传输 ----
    auth_enabled: bool = False
    auth_token: str | None = None
    force_https: bool = False
    pairing_state_path: str = ""
    pairing_discovery_enabled: bool = True
    pairing_discovery_port: int = Field(default=48137, ge=1, le=65535)

    # ---- 笔记多端同步（FR-31/FR-32）----
    sync: SyncConfig = Field(default_factory=SyncConfig)

    # ---- Provider 参数 ----
    providers: ProvidersConfig = Field(default_factory=ProvidersConfig)

    # ------------------------------------------------------------------
    # 数据源装配：init > env > dotenv > YAML > secrets
    # ------------------------------------------------------------------
    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        yaml_source = YamlConfigSettingsSource(settings_cls, yaml_file=resolve_config_file())
        user_config_file = USER_CONFIG_FILE
        if user_config_file.exists() and user_config_file.is_file():
            user_yaml_source = YamlConfigSettingsSource(settings_cls, yaml_file=user_config_file)
            return (
                init_settings,
                env_settings,
                dotenv_settings,
                user_yaml_source,
                yaml_source,
                file_secret_settings,
            )
        return (
            init_settings,
            env_settings,
            dotenv_settings,
            yaml_source,
            file_secret_settings,
        )

    # ------------------------------------------------------------------
    # 便捷属性
    # ------------------------------------------------------------------
    @property
    def is_cloud(self) -> bool:
        """是否云端模式。"""
        return self.deployment_mode == "cloud"

    @property
    def is_sqlite(self) -> bool:
        """当前数据库是否为 SQLite。"""
        return self.db_url.startswith("sqlite")

    @property
    def resolved_handoff_dir(self) -> Path:
        """交接包目录的绝对路径（相对路径基于项目根解析）。"""
        path = Path(self.handoff_dir)
        return path if path.is_absolute() else (PROJECT_ROOT / path)

    @property
    def resolved_storage_root(self) -> Path:
        """本地文件存储根目录。"""
        return Path(self.storage_root)

    @property
    def resolved_recordings_root(self) -> Path:
        """录音目录单独可配；未设置时沿用旧版存储位置。"""
        return Path(self.recordings_root) if self.recordings_root else self.resolved_storage_root / "recordings"

    @property
    def resolved_pairing_state_path(self) -> Path:
        """配对凭据放在电脑应用数据目录，不放进 Obsidian 库。"""
        if self.pairing_state_path:
            return Path(self.pairing_state_path).expanduser().resolve()
        local_data = os.environ.get("LOCALAPPDATA")
        if local_data:
            return Path(local_data) / "ClassNotesAssistant" / "pairing.json"
        return PROJECT_ROOT / "data" / "pairing.json"

    def provider_settings(self, provider_name: str) -> dict[str, Any]:
        """读取指定 Provider 的参数（供 Provider 实现使用）。"""
        return self.providers.for_provider(provider_name).as_dict()


@lru_cache(maxsize=1)
def get_app_config() -> AppConfig:
    """构造并缓存全局 ``AppConfig``（配置的唯一读取入口）。"""
    return AppConfig()


def reset_app_config() -> None:
    """清空配置缓存（供测试在切换环境变量后重新加载）。"""
    get_app_config.cache_clear()


def save_user_config(updates: dict[str, Any]) -> Path:
    """持久化用户个性化配置至 `config.user.yaml`。

    读取已存在的用户配置（如果有），合并 `updates`，再写回。
    写入后自动调用 `reset_app_config()` 刷新缓存。
    """
    import yaml

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    existing: dict[str, Any] = {}
    if USER_CONFIG_FILE.exists() and USER_CONFIG_FILE.is_file():
        try:
            content = USER_CONFIG_FILE.read_text(encoding="utf-8")
            loaded = yaml.safe_load(content)
            if isinstance(loaded, dict):
                existing = loaded
        except Exception:
            existing = {}

    existing.update(updates)
    USER_CONFIG_FILE.write_text(
        yaml.safe_dump(existing, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )
    reset_app_config()
    return USER_CONFIG_FILE
