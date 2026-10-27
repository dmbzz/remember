"""云 LLM Provider（主路径）—— 笔记 / 作业 / 交接三处共用。

关键能力：
    - ``complete``：纯文本补全。
    - ``complete_structured``：**结构化输出**（结构化输出是笔记、作业、交接三处的共同基石）。
      ``LocalLLMProvider`` 复用本实现，仅配置段不同（OpenAI 兼容接口）。
"""

from __future__ import annotations

import json
from typing import Any

from pydantic import BaseModel

from app.errors import ErrorCode, ProviderError
from app.providers.base import (
    LLMMessage,
    LLMOptions,
    LLMProvider,
    ProviderCapabilities,
)

__all__ = ["CloudLLMProvider"]


class CloudLLMProvider(LLMProvider):
    """基于 OpenAI 兼容接口的 LLM 实现（异步）。"""

    default_name = "cloud_llm"

    # ------------------------------------------------------------------
    # 配置
    # ------------------------------------------------------------------
    @property
    def base_url(self) -> str | None:
        value = self.settings().get("base_url")
        return str(value) if value else None

    @property
    def api_key(self) -> str:
        return str(self.settings().get("api_key", "") or "")

    @property
    def model(self) -> str:
        return str(self.settings().get("model", "gpt-4o-mini"))

    @property
    def timeout(self) -> float:
        return float(self.settings().get("timeout", 120.0) or 120.0)

    @property
    def max_retries(self) -> int:
        return int(self.settings().get("max_retries", 3) or 3)

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name=self.name,
            kind="llm",
            runs_offline=self.name == "local_llm",
            incurs_cost=self.name != "local_llm",
            supports_streaming=False,
            extra={"model": self.model, "base_url": self.base_url or "default"},
        )

    # ------------------------------------------------------------------
    # 客户端
    # ------------------------------------------------------------------
    def _client(self):  # noqa: ANN202 - 返回 openai.AsyncOpenAI
        if self.name != "local_llm" and not self.api_key:
            raise ProviderError(
                f"LLM Provider[{self.name}] 未配置 api_key",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        try:
            from openai import AsyncOpenAI
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"未安装 openai SDK：{exc}",
                provider=self.name,
                code=ErrorCode.PROVIDER_UNAVAILABLE,
                retryable=False,
            ) from exc
        return AsyncOpenAI(
            api_key=self.api_key or "not-needed",
            base_url=self.base_url,
            timeout=self.timeout,
            max_retries=self.max_retries,
        )

    @staticmethod
    def _to_payload(messages: list[LLMMessage]) -> list[dict[str, str]]:
        return [{"role": m.role, "content": m.content} for m in messages]

    # ------------------------------------------------------------------
    # 补全
    # ------------------------------------------------------------------
    async def complete(
        self, messages: list[LLMMessage], options: LLMOptions | None = None
    ) -> str:
        """纯文本补全。"""
        opts = options or LLMOptions()
        client = self._client()
        try:
            response = await client.chat.completions.create(  # type: ignore[call-overload]
                model=self.model,
                messages=self._to_payload(messages),
                temperature=opts.temperature,
                max_tokens=opts.max_tokens,
                top_p=opts.top_p,
            )
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"LLM 调用失败：{exc}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CALL_FAILED,
                retryable=_is_retryable(exc),
            ) from exc
        content = response.choices[0].message.content if response.choices else None
        return content or ""

    async def complete_structured(
        self,
        messages: list[LLMMessage],
        schema: type[BaseModel],
        options: LLMOptions | None = None,
    ) -> BaseModel:
        """结构化输出：要求模型返回 JSON 并校验为 ``schema`` 实例。"""
        opts = (options or LLMOptions()).model_copy()
        opts.json_mode = True

        schema_json = json.dumps(schema.model_json_schema(), ensure_ascii=False)
        instruction = LLMMessage(
            role="system",
            content=(
                "你是严格的 JSON 生成器。只输出一个 JSON 对象，不要输出任何解释文字或 Markdown 代码围栏。"
                f"输出必须满足以下 JSON Schema：\n{schema_json}"
            ),
        )
        payload = [instruction, *messages]

        client = self._client()
        try:
            response = await client.chat.completions.create(  # type: ignore[call-overload]
                model=self.model,
                messages=self._to_payload(payload),
                temperature=opts.temperature,
                max_tokens=opts.max_tokens,
                response_format={"type": "json_object"},
            )
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"LLM 结构化调用失败：{exc}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CALL_FAILED,
                retryable=_is_retryable(exc),
            ) from exc

        content = response.choices[0].message.content if response.choices else ""
        return _parse_structured(content or "", schema, self.name)

    def count_tokens(self, text: str) -> int:
        """粗略估算 token 数（优先 tiktoken，缺失则用启发式）。"""
        if not text:
            return 0
        try:
            import tiktoken  # type: ignore[import-not-found]

            return len(tiktoken.get_encoding("cl100k_base").encode(text))
        except Exception:  # noqa: BLE001 - tiktoken 为可选依赖
            return max(1, len(text) // 2)


def _is_retryable(exc: Exception) -> bool:
    """判断异常是否可重试（网络/限流 → True）。"""
    text = str(exc).lower()
    retryable_markers = ("timeout", "timed out", "rate limit", "429", "connection", "502", "503")
    return any(marker in text for marker in retryable_markers)


def _extract_json(text: str) -> str:
    """从可能含围栏/前后缀的文本中提取 JSON 对象字面量。"""
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.strip("`")
        if "\n" in stripped:
            stripped = stripped.split("\n", 1)[1]
        stripped = stripped.strip()
    if stripped.startswith("{"):
        return stripped
    start = stripped.find("{")
    end = stripped.rfind("}")
    if start != -1 and end != -1 and end > start:
        return stripped[start : end + 1]
    return stripped


def _parse_structured(content: str, schema: type[BaseModel], provider: str) -> BaseModel:
    """将 LLM 返回文本解析为 ``schema`` 实例（含容错）。"""
    candidate = _extract_json(content)
    try:
        return schema.model_validate_json(candidate)
    except Exception:  # noqa: BLE001 - 兜底：先 json.loads 再校验
        try:
            data: Any = json.loads(candidate)
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"结构化输出无法解析为 JSON：{exc}",
                provider=provider,
                code=ErrorCode.PROVIDER_CALL_FAILED,
                retryable=True,
            ) from exc
        try:
            return schema.model_validate(data)
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"结构化输出不满足 schema {schema.__name__}：{exc}",
                provider=provider,
                code=ErrorCode.PROVIDER_CALL_FAILED,
                retryable=False,
            ) from exc
