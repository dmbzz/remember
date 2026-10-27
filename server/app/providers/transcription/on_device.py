"""端上转写 Provider —— 占位实现，但**接口完备**（M5 后由端上填充）。

M0 阶段不接入端上推理；调用时抛 ``PROVIDER_UNAVAILABLE``（不可重试），
能力声明为可离线、零成本，保证上层业务对四种形态无感。
"""

from __future__ import annotations

from app.errors import ErrorCode, ProviderError
from app.providers.base import (
    CostEstimate,
    ProviderCapabilities,
    TranscriptResult,
    TranscribeOptions,
    TranscriptionProvider,
)

__all__ = ["OnDeviceProvider"]


class OnDeviceProvider(TranscriptionProvider):
    """端上转写占位实现（接口与其它转写 Provider 完全一致）。"""

    default_name = "on_device"

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name=self.name,
            kind="transcription",
            runs_offline=True,
            incurs_cost=False,
            max_input_seconds=None,
            supports_streaming=False,
            extra={"implemented": False, "planned_milestone": "M5+"},
        )

    def estimate_cost(self, duration_sec: float) -> CostEstimate:
        """端上转写零成本。"""
        return CostEstimate(
            provider=self.name,
            duration_sec=float(duration_sec),
            unit_price_per_hour=0.0,
            estimated_cost=0.0,
            incurs_cost=False,
        )

    async def transcribe(
        self, audio_path: str, options: TranscribeOptions | None = None
    ) -> TranscriptResult:
        """端上转写尚未实现（M5 后接入）。"""
        raise ProviderError(
            "端上转写（on_device）尚未实现，计划在 M5 之后接入",
            provider=self.name,
            code=ErrorCode.PROVIDER_UNAVAILABLE,
            retryable=False,
        )
