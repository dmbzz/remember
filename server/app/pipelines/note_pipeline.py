"""笔记生成流水线（Pipelines · 架构设计 §1.2、T3-02）。"""

from __future__ import annotations

from app.schemas.note import NoteDTO, NoteGenerateRequest
from app.services.note_generation_service import NoteGenerationService

__all__ = ["NotePipeline"]


class NotePipeline:
    """融合式单文件笔记生成流水线。"""

    def __init__(self, service: NoteGenerationService | None = None) -> None:
        self.service = service or NoteGenerationService()

    async def run(self, request: NoteGenerateRequest) -> tuple[NoteDTO, str, dict[str, int]]:
        return await self.service.generate_note(request)
