"""云 ASR 转写 Provider —— **真实可调用**（FR-06 真实 P0）。

实现约定：
    - 面向 OpenAI 兼容的 ``/audio/transcriptions`` 接口（供应商可替换，见 PRD R-02）。
    - 需 ``endpoint`` + ``api_key``；按量计费，驱动 UsageService。
    - 网络/限流错误可重试（tenacity）；配置/鉴权错误不可重试。
"""

from __future__ import annotations

import contextlib
import wave
from pathlib import Path

import httpx
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from app.errors import ErrorCode, ProviderError
from app.providers.base import (
    CostEstimate,
    ProviderCapabilities,
    TranscriptResult,
    TranscriptSegment,
    TranscribeOptions,
    TranscriptionProvider,
)

__all__ = ["CloudASRProvider", "RetryableCloudError"]


class RetryableCloudError(Exception):
    """可重试的云调用错误（网络/限流）。"""


def _probe_duration_sec(audio_path: str) -> float:
    """尽力探测音频时长：WAV 用标准库，其余格式返回 0.0（由 options.extra 提供）。"""
    try:
        with contextlib.closing(wave.open(audio_path, "rb")) as handle:
            frames = handle.getnframes()
            rate = handle.getframerate() or 1
            return frames / float(rate)
    except Exception:  # noqa: BLE001 - 非 wav / 损坏文件不影响主流程
        return 0.0


class CloudASRProvider(TranscriptionProvider):
    """云 ASR 转写实现（OpenAI 兼容接口）。"""

    default_name = "cloud_api"

    @property
    def endpoint(self) -> str:
        return str(self.settings().get("endpoint", "") or "")

    @property
    def api_key(self) -> str:
        return str(self.settings().get("api_key", "") or "")

    @property
    def model(self) -> str:
        return str(self.settings().get("model", "whisper-1"))

    @property
    def unit_price_per_hour(self) -> float:
        return float(self.settings().get("unit_price_per_hour", 0.0) or 0.0)

    @property
    def timeout(self) -> float:
        return float(self.settings().get("timeout", 600.0) or 600.0)

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name=self.name,
            kind="transcription",
            runs_offline=False,
            incurs_cost=True,
            max_input_seconds=None,
            supports_streaming=False,
            extra={"endpoint": self.endpoint, "model": self.model},
        )

    def estimate_cost(self, duration_sec: float) -> CostEstimate:
        hours = max(0.0, float(duration_sec)) / 3600.0
        cost = hours * self.unit_price_per_hour
        return CostEstimate(
            provider=self.name,
            duration_sec=float(duration_sec),
            unit_price_per_hour=self.unit_price_per_hour,
            estimated_cost=round(cost, 6),
            incurs_cost=True,
        )

    def _ensure_configured(self) -> None:
        if not self.endpoint:
            raise ProviderError(
                "云 ASR 未配置 endpoint（供应商与单价 M6 前确定，见 PRD R-02）",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        if not self.api_key:
            raise ProviderError(
                "云 ASR 未配置 api_key",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=1, max=8),
        retry=retry_if_exception_type(RetryableCloudError),
        reraise=True,
    )
    async def _post(self, audio_path: str, options: TranscribeOptions) -> dict:
        headers = {"Authorization": f"Bearer {self.api_key}"}
        data = {"model": self.model, "language": options.language, "response_format": "verbose_json"}
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                with Path(audio_path).open("rb") as handle:
                    files = {"file": (Path(audio_path).name, handle)}
                    response = await client.post(
                        self.endpoint, headers=headers, data=data, files=files
                    )
        except (httpx.TransportError, httpx.TimeoutException) as exc:
            raise RetryableCloudError(f"云 ASR 网络错误：{exc}") from exc

        if response.status_code == 429 or response.status_code >= 500:
            raise RetryableCloudError(f"云 ASR 返回 {response.status_code}：{response.text[:200]}")
        if response.status_code in (401, 403):
            raise ProviderError(
                "云 ASR 鉴权失败（api_key 无效）",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        if response.status_code >= 400:
            raise ProviderError(
                f"云 ASR 调用失败 {response.status_code}：{response.text[:200]}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CALL_FAILED,
                retryable=False,
            )
        try:
            return response.json()
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"云 ASR 返回内容非 JSON：{exc}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CALL_FAILED,
                retryable=False,
            ) from exc

    async def transcribe(
        self, audio_path: str, options: TranscribeOptions | None = None
    ) -> TranscriptResult:
        """调用云 ASR 完成转写。"""
        self._ensure_configured()
        path = Path(audio_path)
        if not path.exists():
            raise ProviderError(
                f"音频文件不存在：{audio_path}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        opts = options or TranscribeOptions()

        try:
            payload = await self._post(str(path), opts)
        except RetryableCloudError as exc:
            raise ProviderError(
                str(exc),
                provider=self.name,
                code=ErrorCode.PROVIDER_CALL_FAILED,
                retryable=True,
            ) from exc

        segments = [
            TranscriptSegment(
                start=float(seg.get("start", 0.0)),
                end=float(seg.get("end", 0.0)),
                text=str(seg.get("text", "")).strip(),
            )
            for seg in (payload.get("segments") or [])
        ]
        duration = float(payload.get("duration") or 0.0)
        if duration <= 0.0:
            extra_duration = opts.model_extra.get("duration_sec") if opts.model_extra else None
            duration = float(extra_duration) if extra_duration else _probe_duration_sec(str(path))
        return TranscriptResult(
            text=str(payload.get("text", "")).strip(),
            provider=self.name,
            language=str(payload.get("language", opts.language)),
            duration_sec=duration,
            segments=segments,
            raw={"model": self.model, "endpoint": self.endpoint},
        )
