"""Provider 工厂冒烟测试：配置 → 正确实现类实例化；新增 Provider 不改业务代码即生效。

对应架构设计附录 A 与 FR-06 验收标准。
"""

from __future__ import annotations

import pytest

from app.config import get_app_config
from app.deps import get_registry, reset_deps
from app.errors import ProviderError
from app.providers.base import (
    LLMProvider,
    StorageProvider,
    TranscriptionProvider,
    VisionProvider,
)
from app.providers.llm.cloud_llm import CloudLLMProvider
from app.providers.llm.local_llm import LocalLLMProvider
from app.providers.registry import ProviderRegistry
from app.providers.storage.local_fs import LocalFileStorageProvider
from app.providers.storage.object_store import ObjectStorageProvider
from app.providers.transcription.cloud_api import CloudASRProvider
from app.providers.transcription.local_gpu import LocalGPUWhisperProvider
from app.providers.transcription.on_device import OnDeviceProvider
from app.providers.vision.cloud_vision import CloudVisionProvider
from app.providers.vision.local_vision import LocalVisionProvider


def test_local_config_builds_local_implementations() -> None:
    """本地配置 → 本地实现类（local_gpu / local_fs / cloud_llm / cloud_vision）。"""
    registry = get_registry()

    transcription = registry.build_transcription()
    assert isinstance(transcription, TranscriptionProvider)
    assert isinstance(transcription, LocalGPUWhisperProvider)

    storage = registry.build_storage()
    assert isinstance(storage, StorageProvider)
    assert isinstance(storage, LocalFileStorageProvider)

    assert isinstance(registry.build_llm(), CloudLLMProvider)
    assert isinstance(registry.build_vision(), CloudVisionProvider)


def test_local_gpu_capabilities_and_cost() -> None:
    """本地转写：可离线、零成本。"""
    provider = get_registry().build_transcription()
    caps = provider.capabilities()
    assert caps.kind == "transcription"
    assert caps.runs_offline is True
    assert caps.incurs_cost is False
    estimate = provider.estimate_cost(3600.0)
    assert estimate.estimated_cost == 0.0
    assert estimate.incurs_cost is False


def test_switching_provider_via_config(monkeypatch: pytest.MonkeyPatch) -> None:
    """配置切换转写 Provider → 实例化不同实现（同一份音频可换 Provider）。"""
    monkeypatch.setenv("CNA_TRANSCRIPTION_PROVIDER", "cloud_api")
    from app.config import reset_app_config

    reset_app_config()
    reset_deps()
    registry = get_registry()
    provider = registry.build_transcription()
    assert isinstance(provider, CloudASRProvider)
    caps = provider.capabilities()
    assert caps.incurs_cost is True
    assert caps.runs_offline is False


def test_on_device_is_registered_and_interface_complete() -> None:
    """端上 Provider 占位但接口完备（可被工厂构建）。"""
    provider = ProviderRegistry(get_app_config()).build_transcription("on_device")
    assert isinstance(provider, OnDeviceProvider)
    assert provider.capabilities().runs_offline is True


def test_all_kinds_buildable_with_explicit_names() -> None:
    """四类 Provider 的所有已注册实现均可显式构建。"""
    registry = ProviderRegistry(get_app_config())
    assert isinstance(registry.build_llm("local_llm"), LocalLLMProvider)
    assert isinstance(registry.build_vision("local_vision"), LocalVisionProvider)
    assert isinstance(registry.build_storage("object_store"), ObjectStorageProvider)
    assert isinstance(registry.build_llm(), LLMProvider)
    assert isinstance(registry.build_vision(), VisionProvider)


def test_new_provider_requires_no_business_change() -> None:
    """FR-06：新增 Provider 只需注册，不改上层业务代码即生效。"""
    alias = "alias_local_gpu"
    ProviderRegistry.register(
        "transcription",
        alias,
        "app.providers.transcription.local_gpu:LocalGPUWhisperProvider",
    )
    assert alias in ProviderRegistry.available("transcription")
    provider = ProviderRegistry(get_app_config()).build_transcription(alias)
    assert isinstance(provider, LocalGPUWhisperProvider)


def test_unknown_provider_raises_provider_error() -> None:
    """未注册的 Provider → ProviderError（不可重试）。"""
    registry = get_registry()
    with pytest.raises(ProviderError) as excinfo:
        registry.build_transcription("does_not_exist")
    assert excinfo.value.retryable is False


def test_named_providers_are_cached() -> None:
    """同一 Provider 重复构建返回同一实例（缓存）。"""
    registry = get_registry()
    assert registry.build_transcription() is registry.build_transcription()
