"""Read existing Obsidian classroom Markdown files without importing or modifying them."""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone
from pathlib import Path

from app.config import AppConfig
from app.errors import ApiError, ErrorCode
from app.schemas.note import NoteDTO

_DATE_SUFFIX = re.compile(r"_(\d{4}-\d{2}-\d{2})$")


class VaultNotesService:
    def __init__(self, config: AppConfig) -> None:
        self.root = Path(config.obsidian_root).resolve()
        self.notes_root = self.root / "课堂笔记"

    def _files(self):
        if not self.notes_root.is_dir():
            return
        for file in self.notes_root.rglob("*"):
            if file.suffix.lower() != ".md":
                continue
            relative = file.relative_to(self.notes_root)
            if any(part.startswith("00-") or part.startswith(".") for part in relative.parts):
                continue
            if "转写原文" in relative.parts[:-1]:
                continue
            resolved = file.resolve()
            if not resolved.is_file() or self.notes_root.resolve() not in resolved.parents:
                continue
            yield file

    def _dto(self, file: Path) -> NoteDTO:
        relative = file.relative_to(self.root).as_posix()
        match = _DATE_SUFFIX.search(file.stem)
        topic = file.stem[: match.start()] if match else file.stem
        modified = datetime.fromtimestamp(file.stat().st_mtime, timezone.utc)
        note_id = "vault_" + hashlib.sha256(relative.encode("utf-8")).hexdigest()[:32]
        return NoteDTO(
            id=note_id,
            note_id=note_id,
            course_name=file.parent.name if file.parent != self.notes_root else "未分类",
            topic=topic,
            obsidian_path=relative,
            origin="win",
            created_at=modified,
            updated_at=modified,
            class_date=match.group(1) if match else None,
        )

    def list(self, course: str | None = None, query: str | None = None) -> list[NoteDTO]:
        items = [self._dto(file) for file in self._files()]
        if course:
            items = [item for item in items if item.course_name == course]
        if query:
            needle = query.casefold()
            items = [item for item in items if needle in item.topic.casefold()]
        items.sort(key=lambda item: item.updated_at, reverse=True)
        return items

    def manifest(self) -> list[dict[str, str]]:
        """只返回相对路径和内容摘要，供手机本地 Obsidian 目录比对。"""
        if not self.notes_root.is_dir():
            raise ApiError(ErrorCode.NOTE_ERROR, "电脑课堂笔记目录不存在或不可用，请检查笔记保存路径")
        items: list[dict[str, str]] = []
        for file in self._files():
            before = file.stat()
            digest = hashlib.sha256()
            with file.open("rb") as source:
                for block in iter(lambda: source.read(65536), b""):
                    digest.update(block)
            after = file.stat()
            if before.st_mtime_ns != after.st_mtime_ns or before.st_size != after.st_size:
                raise ApiError(ErrorCode.NOTE_ERROR, "电脑笔记正在更新，请稍后重新核对")
            items.append({"path": file.relative_to(self.notes_root).as_posix(),
                          "sha256": digest.hexdigest()})
        items.sort(key=lambda item: item["path"])
        return items

    def find(self, note_id: str) -> tuple[NoteDTO, Path]:
        if not note_id.startswith("vault_"):
            raise ApiError(ErrorCode.NOT_FOUND, f"笔记不存在：{note_id}")
        for file in self._files():
            dto = self._dto(file)
            if dto.note_id == note_id:
                return dto, file
        raise ApiError(ErrorCode.NOT_FOUND, f"笔记不存在：{note_id}")

    def read(self, note_id: str) -> tuple[NoteDTO, str]:
        dto, file = self.find(note_id)
        try:
            return dto, file.read_text(encoding="utf-8")
        except OSError as error:
            raise ApiError(ErrorCode.NOTE_ERROR, f"读取笔记失败：{error}") from error
