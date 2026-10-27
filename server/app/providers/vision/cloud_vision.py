"""云视觉 / 多模态 Provider（主路径）—— 教材扫描件、扫描版 PPT 的视觉读取。

版权边界（架构设计 §7.6）：
    只向业务层返回**文字摘录**，**不得直接返回原始图片二进制**。
    扫描原图不进入任何导出/分享产物。
"""

from __future__ import annotations

import asyncio
import base64
from pathlib import Path

from app.errors import ErrorCode, ProviderError
from app.providers.base import ProviderCapabilities, VisionProvider

__all__ = ["CloudVisionProvider"]


class CloudVisionProvider(VisionProvider):
    """基于 OpenAI 兼容多模态接口的视觉实现（异步）。"""

    default_name = "cloud_vision"

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
        return float(self.settings().get("timeout", 180.0) or 180.0)

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name=self.name,
            kind="vision",
            runs_offline=False,
            incurs_cost=True,
            supports_streaming=False,
            extra={"model": self.model, "returns_text_only": True},
        )

    def _client(self):  # noqa: ANN202 - 返回 openai.AsyncOpenAI
        if not self.api_key:
            raise ProviderError(
                f"视觉 Provider[{self.name}] 未配置 api_key",
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
        return AsyncOpenAI(api_key=self.api_key, base_url=self.base_url, timeout=self.timeout)

    @staticmethod
    def _encode_image(image_path: str) -> str:
        """将图片编码为 data URL（仅用于传给视觉模型，不外泄给业务层）。"""
        path = Path(image_path)
        if not path.exists():
            raise ProviderError(
                f"图片不存在：{image_path}",
                provider="cloud_vision",
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        suffix = path.suffix.lower().lstrip(".") or "png"
        mime = "jpeg" if suffix in {"jpg", "jpeg"} else suffix
        data = base64.b64encode(path.read_bytes()).decode("ascii")
        return f"data:image/{mime};base64,{data}"

    async def read_image(self, image_path: str, prompt: str) -> str:
        """视觉读取单张图片，返回文字摘录。"""
        client = self._client()
        data_url = self._encode_image(image_path)
        try:
            response = await client.chat.completions.create(  # type: ignore[call-overload]
                model=self.model,
                messages=[
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": prompt},
                            {"type": "image_url", "image_url": {"url": data_url}},
                        ],
                    }
                ],
            )
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"视觉读取失败：{exc}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CALL_FAILED,
                retryable=True,
            ) from exc
        content = response.choices[0].message.content if response.choices else None
        return content or ""

    @staticmethod
    def _render_pdf_page(pdf_path: str, page_number: int, out_dir: Path) -> Path:
        """用 PyMuPDF 将指定页渲染为 PNG（纯扫描件必需）。``page_number`` 为 1 起。"""
        try:
            import fitz  # PyMuPDF
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"未安装 PyMuPDF：{exc}",
                provider="cloud_vision",
                code=ErrorCode.PROVIDER_UNAVAILABLE,
                retryable=False,
            ) from exc
        document = fitz.open(pdf_path)
        try:
            index = page_number - 1
            if index < 0 or index >= document.page_count:
                raise ProviderError(
                    f"页码越界：{page_number}（共 {document.page_count} 页）",
                    provider="cloud_vision",
                    code=ErrorCode.PROVIDER_CONFIG_ERROR,
                    retryable=False,
                )
            page = document.load_page(index)
            pixmap = page.get_pixmap(matrix=fitz.Matrix(2.2, 2.2))
            out_dir.mkdir(parents=True, exist_ok=True)
            target = out_dir / f"page_{page_number:04d}.png"
            pixmap.save(str(target))
            return target
        finally:
            document.close()

    async def read_pages(self, pdf_path: str, pages: list[int], prompt: str) -> list[str]:
        """渲染 PDF 指定页（``pages`` 为 **1 起的印刷页码**）并逐页视觉读取。"""
        pdf = Path(pdf_path)
        if not pdf.exists():
            raise ProviderError(
                f"PDF 不存在：{pdf_path}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        out_dir = pdf.parent / "tmp_pdf_pages" / pdf.stem
        results: list[str] = []
        for page_number in pages:
            png_path = await asyncio.to_thread(
                self._render_pdf_page, str(pdf), int(page_number), out_dir
            )
            results.append(await self.read_image(str(png_path), prompt))
        return results
