"""Provider 抽象层：四类接口 + 能力/结果类型（架构设计 §3.3）。

共同约定：
    - 所有方法为 **async**；异常统一抛 ``ProviderError(code, provider, retryable)``。
    - Provider 的一切实例化**只在 deps.py 发生**；业务代码只依赖抽象接口。
    - 新增 Provider 只需注册到 ``ProviderRegistry``，**不改上层业务逻辑**（FR-06）。
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from datetime import datetime
from typing import Any, ClassVar, Literal

from pydantic import BaseModel, ConfigDict, Field

__all__ = [
    "ProviderKind",
    "ProviderCapabilities",
    "CostEstimate",
    "TranscribeOptions",
    "TranscriptSegment",
    "TranscriptResult",
    "LLMMessage",
    "Message",
    "LLMOptions",
    "BlobMeta",
    "TranscriptionProvider",
    "LLMProvider",
    "VisionProvider",
    "StorageProvider",
    "BaseProvider",
]

ProviderKind = Literal["transcription", "llm", "vision", "storage"]


# ---------------------------------------------------------------------------
# 通用类型
# ---------------------------------------------------------------------------
class ProviderCapabilities(BaseModel):
    """Provider 能力描述（决定能否离线 / 是否计费）。"""

    name: str
    kind: ProviderKind
    runs_offline: bool = False
    incurs_cost: bool = False
    max_input_seconds: int | None = None
    supports_streaming: bool = False
    extra: dict[str, Any] = Field(default_factory=dict)


class CostEstimate(BaseModel):
    """成本预估（驱动 UsageService）。"""

    provider: str
    duration_sec: float = 0.0
    unit_price_per_hour: float = 0.0
    estimated_cost: float = 0.0
    currency: str = "CNY"
    incurs_cost: bool = False


class TranscribeOptions(BaseModel):
    """转写参数（本地默认 float16 / zh / beam_size=5 / vad_filter）。"""

    model_config = ConfigDict(extra="allow")

    language: str = "zh"
    beam_size: int = 5
    vad_filter: bool = True
    compute_type: str = "float16"
    word_timestamps: bool = False
    initial_prompt: str | None = None


class TranscriptSegment(BaseModel):
    """转写分段。"""

    start: float = 0.0
    end: float = 0.0
    text: str = ""


class TranscriptResult(BaseModel):
    """转写结果（统一返回类型）。"""

    text: str
    provider: str
    language: str = "zh"
    duration_sec: float = 0.0
    segments: list[TranscriptSegment] = Field(default_factory=list)
    raw: dict[str, Any] = Field(default_factory=dict)


class LLMMessage(BaseModel):
    """LLM 对话消息。"""

    role: Literal["system", "user", "assistant"]
    content: str


Message = LLMMessage


class BlobMeta(BaseModel):
    """Blob 元数据（纯机制层：大小 / 摘要 / 修改时间）。

    **不掺业务与版本语义**（命名/归档/版本/冲突由 NoteStore 适配器承担）。
    供同步侧以 **hash + mtime** 判定「谁新」，避免依赖多端时钟一致（架构设计 §1.7.1 / §3.6）。

    - ``etag``：存储系统原生摘要（本地 FS = 内容 sha256；S3 = ETag）。
    - ``last_modified``：最后修改时间（UTC）。
    """

    key: str
    size: int = 0
    etag: str | None = None
    last_modified: datetime | None = None
    content_type: str | None = None


class LLMOptions(BaseModel):
    """LLM 调用参数。"""

    temperature: float = 0.2
    max_tokens: int | None = None
    top_p: float | None = None
    json_mode: bool = False


# ---------------------------------------------------------------------------
# 抽象基类
# ---------------------------------------------------------------------------
class BaseProvider(ABC):
    """Provider 基类：持有名称与配置，提供能力查询。"""

    kind: ClassVar[ProviderKind]
    default_name: ClassVar[str] = "base"

    def __init__(self, config: Any, provider_name: str | None = None) -> None:
        self._config = config
        self.name: str = provider_name or self.default_name

    def settings(self) -> dict[str, Any]:
        """读取本 Provider 在配置中的参数段。"""
        getter = getattr(self._config, "provider_settings", None)
        if callable(getter):
            return dict(getter(self.name))
        return {}

    @abstractmethod
    def capabilities(self) -> ProviderCapabilities:
        """返回能力描述。"""


class TranscriptionProvider(BaseProvider):
    """转写 Provider 抽象接口。"""

    kind: ClassVar[ProviderKind] = "transcription"

    @abstractmethod
    async def transcribe(
        self, audio_path: str, options: TranscribeOptions | None = None
    ) -> TranscriptResult:
        """将音频文件转写为文本。"""

    @abstractmethod
    def estimate_cost(self, duration_sec: float) -> CostEstimate:
        """预估转写成本（本地 Provider 恒为零成本）。"""


class LLMProvider(BaseProvider):
    """LLM Provider 抽象接口（笔记 / 作业 / 交接共用）。"""

    kind: ClassVar[ProviderKind] = "llm"

    @abstractmethod
    async def complete(
        self, messages: list[LLMMessage], options: LLMOptions | None = None
    ) -> str:
        """纯文本补全。"""

    @abstractmethod
    async def complete_structured(
        self,
        messages: list[LLMMessage],
        schema: type[BaseModel],
        options: LLMOptions | None = None,
    ) -> BaseModel:
        """结构化输出（返回 ``schema`` 实例）—— 笔记/作业/交接的基石。"""

    @abstractmethod
    def count_tokens(self, text: str) -> int:
        """粗略估算 token 数。"""


class VisionProvider(BaseProvider):
    """视觉/多模态 Provider 抽象接口。

    约定：**不得直接返回原始图片二进制给业务层**（版权边界，架构设计 §7.6）。
    """

    kind: ClassVar[ProviderKind] = "vision"

    @abstractmethod
    async def read_image(self, image_path: str, prompt: str) -> str:
        """读取单张图片并返回文本。"""

    @abstractmethod
    async def read_pages(self, pdf_path: str, pages: list[int], prompt: str) -> list[str]:
        """读取 PDF 指定页（渲染 PNG 后视觉读取），返回每页文本。"""


class StorageProvider(BaseProvider):
    """存储 Provider 抽象接口（本地文件系统 / 对象存储）。

    **保持纯 blob 语义**：只做「字节的存/取/查」，不掺业务与版本语义
    （命名/归档/版本/冲突由 NoteStore 适配器承担，见架构设计 §1.7.2 / §3.5）。
    v3.0 加宽：新增 ``stat`` / ``list_with_meta``，暴露 blob 的 ``size`` / ``etag`` /
    ``last_modified``，以支撑笔记多端同步的 **hash + mtime** 增量 diff（FR-31）。
    """

    kind: ClassVar[ProviderKind] = "storage"

    @abstractmethod
    async def put(self, local_path: str, key: str) -> str:
        """上传本地文件到 ``key``，返回 URI。"""

    @abstractmethod
    async def get(self, key: str, dest_path: str | None = None) -> str:
        """下载 ``key`` 到 ``dest_path``（或临时目录），返回本地路径。"""

    @abstractmethod
    async def delete(self, key: str) -> None:
        """删除 ``key``。"""

    @abstractmethod
    async def exists(self, key: str) -> bool:
        """判断 ``key`` 是否存在。"""

    @abstractmethod
    async def list(self, prefix: str = "") -> list[str]:
        """列出指定前缀下的所有 key。"""

    @abstractmethod
    async def stat(self, key: str) -> BlobMeta:
        """返回单个 blob 的元数据（大小 / 摘要 / mtime）—— 供同步 hash+mtime 判新旧。

        若 ``key`` 不存在，抛 ``ProviderError(code=NOT_FOUND)``。
        """

    @abstractmethod
    async def list_with_meta(self, prefix: str = "") -> list[BlobMeta]:
        """列出指定前缀下的 blob 及其元数据—— 供同步增量 diff（无需先下载正文）。"""

    @abstractmethod
    async def presign_put(self, key: str) -> str:
        """生成直传地址（云端分片上传用；本地实现返回目标文件路径）。"""
