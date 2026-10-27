"""本地视觉 Provider（可选）—— 预留本地多模态模型。

M0 不接入本地视觉模型；调用时抛 ``PROVIDER_UNAVAILABLE``（不可重试）。
云端多模态为主路径（Q-08），本实现仅为保持 Provider 抽象完整。
"""

from __future__ import annotations

from app.errors import ErrorCode, ProviderError
from app.providers.base import ProviderCapabilities, VisionProvider

__all__ = ["LocalVisionProvider"]


class LocalVisionProvider(VisionProvider):
    """本地视觉占位实现（接口完备，未接入推理）。"""

    default_name = "local_vision"

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name=self.name,
            kind="vision",
            runs_offline=True,
            incurs_cost=False,
            extra={"implemented": False, "planned_milestone": "可选（M3 之后）"},
        )

    def _unavailable(self):  # noqa: ANN202
        raise ProviderError(
            "本地视觉（local_vision）尚未接入；请使用 cloud_vision（Q-08 云为主路径）",
            provider=self.name,
            code=ErrorCode.PROVIDER_UNAVAILABLE,
            retryable=False,
        )

    async def read_image(self, image_path: str, prompt: str) -> str:
        self._unavailable()

    async def read_pages(self, pdf_path: str, pages: list[int], prompt: str) -> list[str]:
        self._unavailable()
