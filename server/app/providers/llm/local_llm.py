"""本地 LLM Provider（可选）—— 预留 Ollama 等 OpenAI 兼容本地运行时。

能力较弱、可离线、零成本；接口与 ``CloudLLMProvider`` 完全一致，
复用其实现，仅读取 ``providers.local_llm`` 配置段。
"""

from __future__ import annotations

from app.providers.llm.cloud_llm import CloudLLMProvider

__all__ = ["LocalLLMProvider"]


class LocalLLMProvider(CloudLLMProvider):
    """本地 LLM 实现（OpenAI 兼容接口，默认指向本机 Ollama）。

    复用 ``CloudLLMProvider`` 全部逻辑：基类 ``_client`` 对 ``local_llm``
    不强制 ``api_key``，因此无需覆盖。
    """

    default_name = "local_llm"
