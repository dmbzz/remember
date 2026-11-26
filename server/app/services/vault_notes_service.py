"""Read existing Obsidian classroom Markdown files and image attachments safely."""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from urllib.parse import unquote

from app.config import AppConfig
from app.core.note_sorting import extract_date_from_text, sort_notes_by_title_time
from app.errors import ApiError, ErrorCode
from app.schemas.note import NoteDTO

_DATE_SUFFIX = re.compile(r"_(\d{4}-\d{2}-\d{2})$")

NOTE_IMAGE_SUFFIXES: tuple[str, ...] = (".png", ".jpg", ".jpeg", ".webp", ".gif")
SYNC_ALLOWED_SUFFIXES: tuple[str, ...] = (".md", *NOTE_IMAGE_SUFFIXES)
IMAGE_MEDIA_TYPES: dict[str, str] = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
}
_MAX_IMAGE_BYTES = 10 * 1024 * 1024


def is_image_suffix(path: str) -> bool:
    return Path(path).suffix.lower() in NOTE_IMAGE_SUFFIXES


def is_allowed_sync_suffix(path: str) -> bool:
    return Path(path).suffix.lower() in SYNC_ALLOWED_SUFFIXES


class VaultNotesService:
    def __init__(self, config: AppConfig) -> None:
        self.root = Path(config.obsidian_root).resolve()
        self.notes_root = self.root / "课堂笔记"

    def _scan_files(self, allowed_suffixes: tuple[str, ...]):
        if not self.notes_root.is_dir():
            return
        notes_root_resolved = self.notes_root.resolve()
        for file in self.notes_root.rglob("*"):
            if file.suffix.lower() not in allowed_suffixes:
                continue
            relative = file.relative_to(self.notes_root)
            if any(part.startswith("00-") or part.startswith(".") for part in relative.parts):
                continue
            if "转写原文" in relative.parts[:-1]:
                continue
            resolved = file.resolve()
            if file.is_symlink() or not resolved.is_file() or notes_root_resolved not in resolved.parents:
                continue
            yield file

    def _files(self):
        yield from self._scan_files((".md",))

    def _sync_files(self):
        yield from self._scan_files(SYNC_ALLOWED_SUFFIXES)

    def _dto(self, file: Path) -> NoteDTO:
        relative = file.relative_to(self.root).as_posix()
        match = _DATE_SUFFIX.search(file.stem)
        topic = file.stem[: match.start()] if match else file.stem
        extracted = extract_date_from_text(file.stem)
        class_date = match.group(1) if match else (extracted[1] if extracted else None)
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
            class_date=class_date,
        )

    def list(self, course: str | None = None, query: str | None = None) -> list[NoteDTO]:
        items = [self._dto(file) for file in self._files()]
        if course:
            items = [item for item in items if item.course_name == course]
        if query:
            needle = query.casefold()
            items = [item for item in items if needle in item.topic.casefold()]
        return sort_notes_by_title_time(items, descending=True)

    def manifest(self) -> list[dict[str, str]]:
        """只返回相对路径和内容摘要，供手机本地 Obsidian 目录比对（含课堂图片附件）。"""
        if not self.notes_root.is_dir():
            raise ApiError(ErrorCode.NOTE_ERROR, "电脑课堂笔记目录不存在或不可用，请检查笔记保存路径")
        items: list[dict[str, str]] = []
        for file in self._sync_files():
            before = file.stat()
            digest = hashlib.sha256()
            with file.open("rb") as source:
                for block in iter(lambda: source.read(65536), b""):
                    digest.update(block)
            after = file.stat()
            if before.st_mtime_ns != after.st_mtime_ns or before.st_size != after.st_size:
                raise ApiError(ErrorCode.NOTE_ERROR, "电脑笔记正在更新，请稍后重新核对")
            items.append({
                "path": file.relative_to(self.notes_root).as_posix(),
                "sha256": digest.hexdigest(),
            })
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

    def _validate_image_ref(self, ref: str) -> str:
        cleaned = unquote(ref or "").split("|", 1)[0].split("#", 1)[0].strip()
        if cleaned.startswith("./"):
            cleaned = cleaned[2:]
        lower = cleaned.lower()
        if (
            not cleaned
            or len(cleaned) > 512
            or lower.startswith(("http://", "https://", "data:"))
            or "\\" in cleaned
            or ":" in cleaned
            or "\x00" in cleaned
            or PurePosixPath(cleaned).is_absolute()
        ):
            raise ApiError(ErrorCode.VALIDATION_ERROR, "无效的笔记图片引用")
        parts = cleaned.split("/")
        if (
            len(parts) > 16
            or any(p in ("", ".", "..") or p.startswith((".", "00-")) for p in parts)
            or "转写原文" in parts[:-1]
            or not is_image_suffix(cleaned)
        ):
            raise ApiError(ErrorCode.VALIDATION_ERROR, "仅支持读取课堂笔记目录内的图片附件")
        return cleaned

    def _preferred_dir(self, note_id: str | None, course: str | None) -> Path | None:
        if note_id and note_id.startswith("vault_"):
            try:
                _, note_file = self.find(note_id)
                return note_file.parent
            except ApiError:
                pass
        if course:
            candidate = course.strip()
            if (
                candidate
                and "/" not in candidate
                and "\\" not in candidate
                and not candidate.startswith((".", "00-"))
            ):
                course_dir = self.notes_root / candidate
                if course_dir.is_dir() and not course_dir.is_symlink():
                    return course_dir
        return None

    def _resolve_valid_image(self, candidate: Path) -> Path | None:
        notes_root_resolved = self.notes_root.resolve()
        if not candidate.exists() or candidate.is_symlink():
            return None
        resolved = candidate.resolve()
        if notes_root_resolved not in resolved.parents or not resolved.is_file():
            return None
        if not is_image_suffix(resolved.name):
            return None
        return resolved

    def read_image(
        self,
        ref: str,
        *,
        note_id: str | None = None,
        course: str | None = None,
    ) -> tuple[bytes, str, str]:
        cleaned = self._validate_image_ref(ref)
        if not self.notes_root.is_dir():
            raise ApiError(ErrorCode.NOTE_ERROR, "电脑课堂笔记目录不存在或不可用")

        preferred = self._preferred_dir(note_id, course)
        parts = cleaned.split("/")
        target: Path | None = None

        if len(parts) > 1:
            if preferred is not None:
                target = self._resolve_valid_image(preferred.joinpath(*parts))
            if target is None:
                target = self._resolve_valid_image(self.notes_root.joinpath(*parts))
        else:
            name = parts[0]
            if preferred is not None:
                target = self._resolve_valid_image(preferred / name)
                if target is None:
                    target = self._resolve_valid_image(preferred / "_图" / name)
                if target is None and preferred.is_dir():
                    matches = sorted(
                        (
                            p
                            for p in preferred.rglob("*")
                            if p.name == name and self._resolve_valid_image(p) is not None
                        ),
                        key=lambda p: p.relative_to(self.notes_root).as_posix(),
                    )
                    if matches:
                        target = self._resolve_valid_image(matches[0])
            if target is None:
                all_images = sorted(
                    self._scan_files(NOTE_IMAGE_SUFFIXES),
                    key=lambda p: p.relative_to(self.notes_root).as_posix(),
                )
                exact = next((p for p in all_images if p.name == name), None)
                if exact is None:
                    exact = next((p for p in all_images if p.name.casefold() == name.casefold()), None)
                if exact is not None:
                    target = self._resolve_valid_image(exact)

        if target is None:
            raise ApiError(ErrorCode.NOT_FOUND, f"未找到笔记图片：{cleaned}")

        with target.open("rb") as source:
            data = source.read(_MAX_IMAGE_BYTES + 1)
        if len(data) > _MAX_IMAGE_BYTES:
            raise ApiError(ErrorCode.NOTE_ERROR, "笔记图片超过 10 MB 限制")

        media_type = IMAGE_MEDIA_TYPES[target.suffix.lower()]
        return data, media_type, target.name
