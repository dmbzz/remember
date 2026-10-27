"""Compare Obsidian snapshots; persist metadata only, never write note files."""
from __future__ import annotations

import hashlib
import json
import threading
from datetime import datetime, timezone
from pathlib import PurePosixPath

from pydantic import Field, field_validator

from app.config import AppConfig
from app.errors import ApiError, ErrorCode
from app.schemas.common import StrictRequestModel
from app.services.vault_notes_service import VaultNotesService

_lock = threading.Lock()


class NoteCheckItem(StrictRequestModel):
    path: str = Field(min_length=1, max_length=1024)
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")

    @field_validator("path")
    @classmethod
    def valid_path(cls, value: str) -> str:
        value = value.replace("\\", "/")
        parts = value.split("/")
        if any(part in ("", ".", "..") for part in parts) or ":" in value or "\x00" in value or PurePosixPath(value).is_absolute():
            raise ValueError("笔记路径必须是课堂笔记内的规范相对路径")
        if not value.lower().endswith(".md"):
            raise ValueError("只核对 Markdown 笔记")
        return value


class NoteCheckRequest(StrictRequestModel):
    device_id: str = Field(pattern=r"^[a-f0-9]{32}$")
    folder_label: str = Field(min_length=1, max_length=256)
    folder_id: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")
    items: list[NoteCheckItem] = Field(max_length=5000)

    @field_validator("items")
    @classmethod
    def unique_paths(cls, items: list[NoteCheckItem]) -> list[NoteCheckItem]:
        if len({item.path for item in items}) != len(items):
            raise ValueError("笔记清单包含重复路径")
        return items


class NoteCheckService:
    def __init__(self, config: AppConfig):
        if config.deployment_mode != "local":
            raise ApiError(ErrorCode.VALIDATION_ERROR, "请连接本地电脑核对 Obsidian 笔记")
        self.config = config
        self.directory = config.resolved_pairing_state_path.parent / "note_checks"
        self.vault = VaultNotesService(config)
        self.vault_id = hashlib.sha256(str(self.vault.notes_root.resolve()).encode("utf-8")).hexdigest()

    def _compare(self, snapshot: dict, computer: list[dict]) -> dict:
        local = {item["path"]: item["sha256"] for item in snapshot["items"]}
        remote = {item["path"]: item["sha256"] for item in computer}
        shared = local.keys() & remote.keys()
        different = sorted(path for path in shared if local[path] != remote[path])
        from app.services.note_choice_service import NoteChoiceService, ChoiceScope
        folder_id = snapshot.get("folder_id")
        choices = NoteChoiceService(self.config).list(ChoiceScope(device_id=snapshot["device_id"],
                    folder_id=folder_id, vault_id=self.vault_id)) if folder_id else []
        return {
            "device_id": snapshot["device_id"],
            "folder_label": snapshot["folder_label"],
            "vault_id": self.vault_id,
            "folder_id": folder_id,
            "versions": {path: {"phone_hash": local.get(path), "computer_hash": remote.get(path)}
                         for path in sorted(local.keys() | remote.keys()) if local.get(path) != remote.get(path)},
            "choices": choices,
            "phone_checked_at": snapshot["phone_checked_at"],
            "computer_checked_at": datetime.now(timezone.utc).isoformat(),
            "phone_total": len(local), "computer_total": len(remote),
            "same": len(shared) - len(different),
            "only_on_phone": sorted(local.keys() - remote.keys()),
            "only_on_computer": sorted(remote.keys() - local.keys()),
            "different": different,
        }

    def record(self, request: NoteCheckRequest) -> dict:
        computer = self.vault.manifest()
        snapshot = request.model_dump()
        snapshot.update(vault_id=self.vault_id, phone_checked_at=datetime.now(timezone.utc).isoformat())
        with _lock:
            self.directory.mkdir(parents=True, exist_ok=True)
            target = self.directory / f"{request.device_id}.json"
            temporary = target.with_suffix(".tmp")
            temporary.write_text(json.dumps(snapshot, ensure_ascii=False), encoding="utf-8")
            temporary.replace(target)
        return self._compare(snapshot, computer)

    def reports(self) -> list[dict]:
        computer = self.vault.manifest()
        reports = []
        with _lock:
            for path in self.directory.glob("*.json"):
                snapshot = json.loads(path.read_text(encoding="utf-8"))
                # Results from a different Windows vault cannot describe this vault.
                if snapshot.get("vault_id") != self.vault_id:
                    continue
                NoteCheckRequest.model_validate({key: snapshot.get(key) for key in ("device_id", "folder_label", "folder_id", "items")})
                reports.append(self._compare(snapshot, computer))
        reports.sort(key=lambda item: item["phone_checked_at"], reverse=True)
        return reports
