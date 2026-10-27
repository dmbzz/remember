"""本地 GPU 转写 Provider —— faster-whisper-medium（**AMD ROCm**，非 CUDA）。

参数固定：``float16`` / ``zh`` / ``beam_size=5`` / ``vad_filter=True``（用户已验证）。
零成本、可离线（宿舍断网场景）。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from app.errors import ErrorCode, ProviderError
from app.providers.base import (
    CostEstimate,
    ProviderCapabilities,
    TranscriptResult,
    TranscriptSegment,
    TranscribeOptions,
    TranscriptionProvider,
)

__all__ = ["LocalGPUWhisperProvider"]


class LocalGPUWhisperProvider(TranscriptionProvider):
    """基于 ``faster-whisper`` 的本地 GPU 转写实现。"""

    default_name = "local_gpu"

    def __init__(self, config, provider_name: str | None = None) -> None:  # noqa: ANN001
        super().__init__(config, provider_name)
        self._model = None  # 惰性加载并缓存

    # ------------------------------------------------------------------
    # 配置
    # ------------------------------------------------------------------
    @property
    def model_name(self) -> str:
        return str(self.settings().get("model_name", "faster-whisper-medium"))

    @property
    def device(self) -> str:
        # 注意：AMD 环境为 "rocm" 或 "auto"；**不得假设 "cuda"**
        return str(self.settings().get("device", "rocm"))

    @property
    def compute_type(self) -> str:
        return str(self.settings().get("compute_type", "float16"))

    def _default_options(self) -> TranscribeOptions:
        settings = self.settings()
        return TranscribeOptions(
            language=str(settings.get("language", "zh")),
            beam_size=int(settings.get("beam_size", 5)),
            vad_filter=bool(settings.get("vad_filter", True)),
            compute_type=self.compute_type,
        )

    # ------------------------------------------------------------------
    # 能力 / 成本
    # ------------------------------------------------------------------
    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name=self.name,
            kind="transcription",
            runs_offline=True,
            incurs_cost=False,
            max_input_seconds=None,
            supports_streaming=False,
            extra={"device": self.device, "compute_type": self.compute_type},
        )

    def estimate_cost(self, duration_sec: float) -> CostEstimate:
        """本地转写零成本。"""
        return CostEstimate(
            provider=self.name,
            duration_sec=float(duration_sec),
            unit_price_per_hour=0.0,
            estimated_cost=0.0,
            incurs_cost=False,
        )

    # ------------------------------------------------------------------
    # 转写
    # ------------------------------------------------------------------
    def _load_model(self):  # noqa: ANN202 - 返回 faster_whisper.WhisperModel
        if self._model is not None:
            return self._model
        try:
            from faster_whisper import WhisperModel
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"未安装 faster-whisper 或 ROCm 运行时缺失：{exc}",
                provider=self.name,
                code=ErrorCode.PROVIDER_UNAVAILABLE,
                retryable=False,
            ) from exc
        try:
            self._model = WhisperModel(
                self.model_name,
                device=self.device,
                compute_type=self.compute_type,
            )
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"加载本地转写模型失败（model={self.model_name}, device={self.device}）：{exc}",
                provider=self.name,
                code=ErrorCode.PROVIDER_UNAVAILABLE,
                retryable=False,
            ) from exc
        return self._model

    def _transcribe_sync(self, audio_path: str, options: TranscribeOptions) -> TranscriptResult:
        model = self._load_model()
        segments_iter, info = model.transcribe(
            audio_path,
            language=options.language,
            beam_size=options.beam_size,
            vad_filter=options.vad_filter,
            word_timestamps=options.word_timestamps,
            initial_prompt=options.initial_prompt,
        )
        segments: list[TranscriptSegment] = []
        parts: list[str] = []
        last_end = 0.0
        for segment in segments_iter:
            text = (segment.text or "").strip()
            segments.append(
                TranscriptSegment(start=float(segment.start), end=float(segment.end), text=text)
            )
            parts.append(text)
            last_end = float(segment.end)
        duration = float(getattr(info, "duration", last_end) or last_end)
        return TranscriptResult(
            text="\n".join(p for p in parts if p),
            provider=self.name,
            language=getattr(info, "language", options.language),
            duration_sec=duration,
            segments=segments,
            raw={"model": self.model_name, "device": self.device},
        )

    async def transcribe(
        self, audio_path: str, options: TranscribeOptions | None = None
    ) -> TranscriptResult:
        """异步转写（阻塞的推理放入线程池，避免阻塞事件循环）。"""
        path = Path(audio_path)
        if not path.exists():
            raise ProviderError(
                f"音频文件不存在：{audio_path}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        opts = options or self._default_options()
        return await asyncio.to_thread(self._transcribe_sync, str(path), opts)
