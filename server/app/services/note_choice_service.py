"""Explicit, hash-bound decisions. Store metadata, never losing-version content."""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import threading
from typing import Literal
import uuid

from pydantic import Field

from app.config import AppConfig
from app.errors import ApiError, ErrorCode
from app.schemas.common import StrictRequestModel
from app.services.note_file_sync_service import NoteFileSyncService

_lock = threading.RLock()
Digest = str


class ChoiceScope(StrictRequestModel):
    device_id: str = Field(pattern=r"^[a-f0-9]{32}$")
    folder_id: str = Field(pattern=r"^[a-f0-9]{64}$")
    vault_id: str = Field(pattern=r"^[a-f0-9]{64}$")


class NoteChoiceRequest(ChoiceScope):
    path: str = Field(min_length=1, max_length=1024)
    source: Literal["phone", "computer"]
    phone_hash: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")
    computer_hash: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")


class NoteChoiceApply(ChoiceScope):
    phone_hash: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")
    content_base64: str | None = Field(default=None, max_length=14 * 1024 * 1024)


class NoteChoiceService:
    def __init__(self, config: AppConfig):
        transport = NoteFileSyncService(config)
        self.config, self.vault_id = config, transport.vault_id
        self.root = transport.vault.notes_root.resolve()
        if not self.root.is_dir():
            raise ApiError(ErrorCode.NOTE_ERROR, "电脑课堂笔记目录不可用，请检查保存路径")
        self.directory = config.resolved_pairing_state_path.parent / "note_choices"

    def _file(self, scope: ChoiceScope) -> Path:
        if scope.vault_id != self.vault_id:
            raise ApiError(ErrorCode.CONFLICT, "电脑笔记目录已变化，请重新核对")
        return self.directory / f"{scope.device_id}-{scope.folder_id}-{scope.vault_id}.json"

    def _load(self, scope):
        file = self._file(scope)
        return json.loads(file.read_text("utf-8")) if file.exists() else {}

    def _save(self, scope, records):
        target = self._file(scope)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".tmp")
        with temporary.open("w", encoding="utf-8") as f:
            json.dump(records, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        temporary.replace(target)

    def list(self, scope: ChoiceScope) -> list[dict]:
        with _lock:
            return list(self._load(scope).values())

    def _snapshot(self, scope):
        self._file(scope)
        path = self.config.resolved_pairing_state_path.parent / "note_checks" / f"{scope.device_id}.json"
        if not path.is_file():
            raise ApiError(ErrorCode.CONFLICT, "请先在手机核对笔记")
        snapshot = json.loads(path.read_text("utf-8"))
        if snapshot.get("folder_id") != scope.folder_id or snapshot.get("vault_id") != scope.vault_id:
            raise ApiError(ErrorCode.CONFLICT, "手机目录或电脑笔记库已变化，请重新核对")
        return {item["path"]: item["sha256"] for item in snapshot["items"]}

    def _path(self, path: str) -> Path:
        parts = path.split("/")
        reserved = {"CON", "PRN", "AUX", "NUL"} | {f"{p}{i}" for p in ("COM", "LPT") for i in range(1, 10)}
        if (not path.lower().endswith(".md") or len(parts) > 17 or "\\" in path or ":" in path
                or any(ord(c) < 32 for c in path) or any(p in ("", ".", "..") or p.startswith((".", "00-"))
                or p == "转写原文" or p.endswith((" ", ".")) or p.split(".")[0].upper() in reserved for p in parts)):
            raise ApiError(ErrorCode.VALIDATION_ERROR, "无效的课堂笔记相对路径")
        parent = self.root
        for part in parts:
            if parent.is_dir():
                matches = [p for p in parent.iterdir() if p.name.casefold() == part.casefold()]
                if len(matches) > 1 or (matches and matches[0].name != part):
                    raise ApiError(ErrorCode.CONFLICT, "存在大小写重名笔记，请先处理重名")
            parent = parent / part
            if parent.is_symlink() or getattr(parent, "is_junction", lambda: False)() or not parent.resolve().is_relative_to(self.root):
                raise ApiError(ErrorCode.VALIDATION_ERROR, "同步路径不能跨越笔记目录")
        return parent

    @staticmethod
    def _hash(file):
        if not file.exists():
            return None
        if not file.is_file() or file.stat().st_size > 10 * 1024 * 1024:
            raise ApiError(ErrorCode.VALIDATION_ERROR, "笔记类型或大小不支持同步")
        return hashlib.sha256(file.read_bytes()).hexdigest()

    def choose(self, payload: NoteChoiceRequest) -> dict:
        with _lock:
            phone = self._snapshot(payload).get(payload.path)
            computer = self._hash(self._path(payload.path))
            if phone != payload.phone_hash or computer != payload.computer_hash:
                raise ApiError(ErrorCode.CONFLICT, "笔记版本已变化，请重新核对后选择")
            if phone == computer or (payload.source == "phone" and phone is None) or (payload.source == "computer" and computer is None):
                raise ApiError(ErrorCode.VALIDATION_ERROR, "所选来源没有该笔记，或两端已经一致")
            records = self._load(payload)
            old = records.get(payload.path)
            if old and old["status"] == "pending":
                if all(old[key] == getattr(payload, key) for key in ("source", "phone_hash", "computer_hash")):
                    return old
                raise ApiError(ErrorCode.CONFLICT, "该笔记已有待执行选择，请等待手机处理后重新核对")
            record = {**payload.model_dump(), "id": uuid.uuid4().hex, "status": "pending", "message": "等待手机连接并打开 APP 执行"}
            records[payload.path] = record
            self._save(payload, records)
            return record

    def _record(self, ident, scope):
        records = self._load(scope)
        match = next((r for r in records.values() if r["id"] == ident), None)
        if match is None:
            raise ApiError(ErrorCode.CONFLICT, "这次选择已失效，请重新核对")
        return records, match

    def reject(self, ident: str, scope: ChoiceScope) -> dict:
        with _lock:
            records, record = self._record(ident, scope)
            if record["status"] == "pending":
                record.update(status="stale", message="选择后内容或目录已变化，请重新选择")
                self._save(scope, records)
            return record

    def apply(self, ident: str, payload: NoteChoiceApply) -> dict:
        with _lock:
            records, record = self._record(ident, payload)
            if record["status"] == "completed":
                return record  # A lost receipt must never overwrite a later edit.
            if record["status"] != "pending":
                raise ApiError(ErrorCode.CONFLICT, "这次选择已失效，请重新核对")
            phone = self._snapshot(payload).get(record["path"])
            target = self._path(record["path"])
            computer = self._hash(target)
            if record["source"] == "phone":
                if phone != record["phone_hash"] or payload.phone_hash != record["phone_hash"]:
                    raise ApiError(ErrorCode.CONFLICT, "手机版本已变化，请重新选择")
                try:
                    data = base64.b64decode(payload.content_base64 or "", validate=True)
                except (binascii.Error, ValueError) as exc:
                    raise ApiError(ErrorCode.VALIDATION_ERROR, "笔记传输内容无效") from exc
                if len(data) > 10 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != record["phone_hash"]:
                    raise ApiError(ErrorCode.VALIDATION_ERROR, "手机内容校验失败，电脑原文件未修改")
                if computer not in (record["computer_hash"], record["phone_hash"]):
                    raise ApiError(ErrorCode.CONFLICT, "电脑版本已变化，请重新选择")
                if computer != record["phone_hash"]:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    stage = target.parent / f".cna-choice-{ident}.tmp"
                    try:
                        with stage.open("wb") as f:
                            f.write(data); f.flush(); os.fsync(f.fileno())
                        if self._hash(target) != record["computer_hash"]:
                            raise ApiError(ErrorCode.CONFLICT, "电脑笔记在保存时变化，未覆盖")
                        stage.replace(target)  # Atomic replace: no retained losing version.
                    finally:
                        stage.unlink(missing_ok=True)
                selected = record["phone_hash"]
            else:
                selected = record["computer_hash"]
                if computer != selected or payload.phone_hash != selected or phone not in (record["phone_hash"], selected):
                    raise ApiError(ErrorCode.CONFLICT, "两端版本已变化，请重新核对后选择")
            record.update(status="completed", message="已同步所选版本；未保留被替换版本", selected_hash=selected)
            self._save(payload, records)
            return record
