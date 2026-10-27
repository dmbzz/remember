"""Provider 抽象层（四类接口 + 工厂 + 实现）。"""

from app.providers.base import (
    BaseProvider,
    CostEstimate,
    LLMMessage,
    LLMOptions,
    LLMProvider,
    ProviderCapabilities,
    ProviderKind,
    StorageProvider,
    TranscriptResult,
    TranscriptSegment,
    TranscribeOptions,
    TranscriptionProvider,
    VisionProvider,
)
from app.providers.registry import ProviderRegistry

__all__ = [
    "BaseProvider",
    "ProviderCapabilities",
    "ProviderKind",
    "CostEstimate",
    "TranscribeOptions",
    "TranscriptSegment",
    "TranscriptResult",
    "LLMMessage",
    "LLMOptions",
    "TranscriptionProvider",
    "LLMProvider",
    "VisionProvider",
    "StorageProvider",
    "ProviderRegistry",
]
