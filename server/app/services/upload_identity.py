"""Stable upload ownership across local pairing and cloud deployments."""
from __future__ import annotations

import json
import os
import re
import secrets
import tempfile
from pathlib import Path

from app.config import get_app_config
from app.errors import ApiError, ErrorCode


def _cloud_server_id(root: Path) -> str:
    path = root / "server-identity.json"
    temporary = None
    try:
        root.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            # Publish a fully written identity without replacing another worker's
            # winner. All workers must share this persistent storage directory.
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=root,
                prefix=".server-identity-", suffix=".tmp", delete=False,
            ) as stream:
                temporary = Path(stream.name)
                json.dump({"server_id": secrets.token_hex(8)}, stream)
                stream.flush()
                os.fsync(stream.fileno())
            try:
                os.link(temporary, path)
            except FileExistsError:
                pass
        value = json.loads(path.read_text(encoding="utf-8"))
        identity = value.get("server_id") if isinstance(value, dict) else None
        if not isinstance(identity, str) or not re.fullmatch(r"[0-9a-f]{16}", identity):
            raise ValueError("invalid upload identity")
        return identity
    except (OSError, ValueError) as exc:
        # Never invent a replacement identity for an unreadable/corrupt store.
        raise ApiError(ErrorCode.CONFIG_ERROR, "服务器上传身份无法确认，请检查持久存储目录") from exc
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def upload_server_id(app) -> str:
    config = get_app_config()
    if config.deployment_mode == "local":
        return app.state.pairing_service.public_identity()["server_id"]
    return _cloud_server_id(config.resolved_storage_root)
