"""笔记服务汇总导出（T3-02）。"""

from __future__ import annotations

from app.services.note_generation_service import NoteGenerationService

__all__ = ["NoteService", "NoteGenerationService"]

# 别名，保持服务层命名习惯
NoteService = NoteGenerationService
