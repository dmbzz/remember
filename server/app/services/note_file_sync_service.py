"""Read-only, byte-preserving Windows -> phone notebook transport."""
from __future__ import annotations

import base64
import hashlib
from pathlib import PurePosixPath

from app.config import AppConfig
from app.errors import ApiError, ErrorCode
from app.services.vault_notes_service import VaultNotesService


class NoteFileSyncService:
    limit = 10 * 1024 * 1024

    def __init__(self, config: AppConfig):
        if config.deployment_mode != "local":
            raise ApiError(ErrorCode.VALIDATION_ERROR, "请连接电脑同步笔记")
        self.vault = VaultNotesService(config)
        self.vault_id = hashlib.sha256(str(self.vault.notes_root.resolve()).encode("utf-8")).hexdigest()

    def manifest(self) -> dict:
        items = self.vault.manifest()
        if len(items) > 5000:
            raise ApiError(ErrorCode.NOTE_ERROR, "笔记超过5000篇，请缩小同步目录")
        return {"vault_id": self.vault_id, "items": items, "total": len(items)}

    def content(self, path: str, sha256: str, vault_id: str) -> dict:
        if vault_id != self.vault_id:
            raise ApiError(ErrorCode.NOTE_ERROR, "电脑笔记目录已变化，请重新同步")
        parts = path.split("/")
        if (len(path) > 1024 or len(parts) > 17 or any(p in ("", ".", "..") or p.startswith((".", "00-")) for p in parts)
                or "\\" in path or ":" in path or "\x00" in path or "转写原文" in parts[:-1]
                or PurePosixPath(path).is_absolute() or not path.lower().endswith(".md")):
            raise ApiError(ErrorCode.VALIDATION_ERROR, "无效的课堂笔记相对路径")
        root = self.vault.notes_root.resolve()
        file = root.joinpath(*parts).resolve()
        if root not in file.parents or not file.is_file():
            raise ApiError(ErrorCode.NOT_FOUND, "该笔记已移动或不在同步目录")
        # Bound before loading and read only. No decoding or newline normalization.
        with file.open("rb") as source:
            data = source.read(self.limit + 1)
        if len(data) > self.limit:
            raise ApiError(ErrorCode.NOTE_ERROR, "笔记超过10 MB，无法同步")
        digest = hashlib.sha256(data).hexdigest()
        if digest != sha256:
            raise ApiError(ErrorCode.NOTE_ERROR, "笔记在同步时已更新，请重新同步")
        return {"path": path, "sha256": digest, "bytes": len(data), "content_base64": base64.b64encode(data).decode("ascii")}
