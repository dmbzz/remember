"""Provider 工厂（配置驱动，架构设计 §3.3）。

设计要点：
    - 通过 ``_NAME → "module:Class"`` 常量表注册实现，**惰性 import**（避免重依赖即时加载）。
    - 新增 Provider 只需调用 ``register_*`` 或补充常量表，**不改上层业务逻辑**（FR-06）。
    - 实例缓存：同一 ``(kind, name)`` 只构造一次。
"""

from __future__ import annotations

import importlib
from typing import Any

from app.config import AppConfig
from app.errors import ErrorCode, ProviderError
from app.providers.base import (
    LLMProvider,
    StorageProvider,
    TranscriptionProvider,
    VisionProvider,
)

__all__ = ["ProviderRegistry"]

# 名称 → 实现类路径（module:ClassName）
_TRANSCRIPTION_REGISTRY: dict[str, str] = {
    "local_gpu": "app.providers.transcription.local_gpu:LocalGPUWhisperProvider",
    "cloud_api": "app.providers.transcription.cloud_api:CloudASRProvider",
    "on_device": "app.providers.transcription.on_device:OnDeviceProvider",
}

_LLM_REGISTRY: dict[str, str] = {
    "cloud_llm": "app.providers.llm.cloud_llm:CloudLLMProvider",
    "local_llm": "app.providers.llm.local_llm:LocalLLMProvider",
}

_VISION_REGISTRY: dict[str, str] = {
    "cloud_vision": "app.providers.vision.cloud_vision:CloudVisionProvider",
    "local_vision": "app.providers.vision.local_vision:LocalVisionProvider",
}

_STORAGE_REGISTRY: dict[str, str] = {
    "local_fs": "app.providers.storage.local_fs:LocalFileStorageProvider",
    "object_store": "app.providers.storage.object_store:ObjectStorageProvider",
}

_REGISTRIES: dict[str, dict[str, str]] = {
    "transcription": _TRANSCRIPTION_REGISTRY,
    "llm": _LLM_REGISTRY,
    "vision": _VISION_REGISTRY,
    "storage": _STORAGE_REGISTRY,
}


def _load_class(path: str, kind: str, name: str) -> type:
    """按 ``module:Class`` 惰性加载实现类。"""
    module_path, _, class_name = path.partition(":")
    try:
        module = importlib.import_module(module_path)
    except Exception as exc:  # noqa: BLE001 - 依赖缺失等统一转 ProviderError
        raise ProviderError(
            f"无法加载 Provider 实现模块 {module_path}：{exc}",
            provider=name,
            code=ErrorCode.PROVIDER_UNAVAILABLE,
            retryable=False,
        ) from exc
    try:
        return getattr(module, class_name)
    except AttributeError as exc:
        raise ProviderError(
            f"Provider 实现类 {class_name} 不存在于 {module_path}",
            provider=name,
            code=ErrorCode.PROVIDER_NOT_FOUND,
            retryable=False,
        ) from exc


class ProviderRegistry:
    """Provider 工厂：按配置装配四类 Provider（唯一实例化入口之一，由 deps 调用）。"""

    def __init__(self, config: AppConfig) -> None:
        self._config = config
        self._instances: dict[tuple[str, str], Any] = {}

    # ------------------------------------------------------------------
    # 注册（扩展点）
    # ------------------------------------------------------------------
    @staticmethod
    def register(kind: str, name: str, path: str) -> None:
        """注册（或覆盖）某类 Provider 的实现。``path`` 形如 ``module:Class``。"""
        if kind not in _REGISTRIES:
            raise ProviderError(
                f"未知 Provider 类别：{kind}",
                provider=name,
                code=ErrorCode.PROVIDER_NOT_FOUND,
                retryable=False,
            )
        _REGISTRIES[kind][name] = path

    @staticmethod
    def available(kind: str) -> list[str]:
        """列出某类已注册的 Provider 名称。"""
        return sorted(_REGISTRIES.get(kind, {}).keys())

    # ------------------------------------------------------------------
    # 构建
    # ------------------------------------------------------------------
    def _build(self, kind: str, name: str) -> Any:
        registry = _REGISTRIES.get(kind)
        if registry is None:
            raise ProviderError(
                f"未知 Provider 类别：{kind}",
                provider=name,
                code=ErrorCode.PROVIDER_NOT_FOUND,
                retryable=False,
            )
        key = (kind, name)
        if key in self._instances:
            return self._instances[key]
        path = registry.get(name)
        if path is None:
            raise ProviderError(
                f"未注册的 {kind} Provider：{name}",
                provider=name,
                code=ErrorCode.PROVIDER_NOT_FOUND,
                retryable=False,
            )
        cls = _load_class(path, kind, name)
        instance = cls(self._config, provider_name=name)
        self._instances[key] = instance
        return instance

    def build_transcription(self, name: str | None = None) -> TranscriptionProvider:
        """构建转写 Provider（默认取配置项）。"""
        return self._build("transcription", name or self._config.transcription_provider)

    def build_llm(self, name: str | None = None) -> LLMProvider:
        """构建 LLM Provider（默认取配置项）。"""
        return self._build("llm", name or self._config.llm_provider)

    def build_vision(self, name: str | None = None) -> VisionProvider:
        """构建视觉 Provider（默认取配置项）。"""
        return self._build("vision", name or self._config.vision_provider)

    def build_storage(self, name: str | None = None) -> StorageProvider:
        """构建存储 Provider（默认取配置项）。"""
        return self._build("storage", name or self._config.storage_backend)
