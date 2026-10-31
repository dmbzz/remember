"""局域网手机配对：限时 PIN 换取可撤销的设备令牌。"""

from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import socket
import threading
import time
from pathlib import Path
from typing import Any

__all__ = ["PairingService", "PairingError"]


class PairingError(Exception):
    def __init__(self, message: str, status_code: int = 400) -> None:
        super().__init__(message)
        self.status_code = status_code


class PairingService:
    """进程内缓存凭据；仅令牌哈希写入本机文件。"""

    _code_seconds = 600
    _max_attempts = 5

    def __init__(self, state_path: Path, port: int) -> None:
        self._path = state_path
        self._port = port
        self._lock = threading.RLock()
        self._state: dict[str, Any] | None = None
        self._attempts: dict[str, list[float]] = {}

    def _load(self) -> dict[str, Any]:
        if self._state is not None:
            return self._state
        if self._path.exists():
            state = json.loads(self._path.read_text(encoding="utf-8"))
            if not isinstance(state, dict) or not isinstance(state.get("secret"), str):
                raise PairingError("配对状态文件损坏，请在电脑上检查该文件", 500)
            if not isinstance(state.get("tokens"), dict):
                raise PairingError("配对状态文件格式错误", 500)
            self._state = state
        else:
            self._state = {"secret": secrets.token_hex(32), "tokens": {}}
            self._save()
        return self._state

    def _save(self) -> None:
        assert self._state is not None
        self._path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self._path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self._state, ensure_ascii=False), encoding="utf-8")
        try:
            os.chmod(temporary, 0o600)
        except OSError:
            pass
        temporary.replace(self._path)

    def _pin(self, period: int) -> str:
        state = self._load()
        digest = hmac.new(
            bytes.fromhex(state["secret"]), str(period).encode(), hashlib.sha256
        ).digest()
        return f"{int.from_bytes(digest[:8], 'big') % 1_000_000:06d}"

    @staticmethod
    def lan_addresses() -> list[str]:
        """优先显示当前默认路由的 IPv4，再补充主机上的其他可用地址。"""
        found: list[str] = []

        def add(value: str) -> None:
            try:
                addr = ipaddress.ip_address(value)
            except ValueError:
                return
            if (
                isinstance(addr, ipaddress.IPv4Address)
                and not addr.is_loopback
                and not addr.is_link_local
                and not addr.is_unspecified
                and not addr.is_multicast
                and not addr.is_reserved
                and value not in found
            ):
                found.append(value)

        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect(("192.0.2.1", 9))  # 只查询路由，不发送数据
                add(sock.getsockname()[0])
        except OSError:
            pass
        try:
            for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                add(item[4][0])
        except OSError:
            pass
        return found

    def info(self) -> dict[str, Any]:
        with self._lock:
            now = int(time.time())
            pin = self._pin(now // self._code_seconds)
            addresses = self.lan_addresses()
            return {
                **self.public_identity(),
                "code": pin,
                "expires_in_seconds": self._code_seconds - now % self._code_seconds,
                "addresses": addresses,
                "connection_codes": [f"{ip}:{self._port}#{pin}" for ip in addresses],
                "paired_devices": len(self._load()["tokens"]),
            }

    def public_identity(self) -> dict[str, Any]:
        """可公开发现的电脑身份；不包含 PIN、密钥或设备令牌。"""
        with self._lock:
            server_id = hmac.new(
                bytes.fromhex(self._load()["secret"]), b"pairing-server-id-v1", hashlib.sha256
            ).hexdigest()[:16]
            name = "".join(char for char in socket.gethostname() if char.isprintable())[:64]
            return {"server_id": server_id, "name": name or "Remember", "port": self._port}

    def _validate_code(self, code: str, client_host: str, server_id: str | None) -> None:
        """resolve 与 exchange 共用错误次数；正确探测不占用剩余配额。"""
        now = time.monotonic()
        attempts = [at for at in self._attempts.get(client_host, []) if now - at < 300]
        if len(attempts) >= self._max_attempts:
            raise PairingError("尝试次数过多，请五分钟后重试", 429)
        pin_matches = code.isascii() and hmac.compare_digest(
            code, self._pin(int(time.time()) // self._code_seconds)
        )
        identity_matches = server_id is None or (
            server_id.isascii()
            and hmac.compare_digest(server_id, self.public_identity()["server_id"])
        )
        if not pin_matches or not identity_matches:
            attempts.append(now)
            self._attempts[client_host] = attempts
            raise PairingError("连接码错误或已过期", 403)

    def resolve(
        self, code: str, client_host: str, server_id: str | None = None
    ) -> dict[str, Any]:
        """验证短码并确认电脑身份，不创建令牌或保存配对状态。"""
        with self._lock:
            self._validate_code(code, client_host, server_id)
            return self.public_identity()

    def exchange(
        self, code: str, device_name: str, client_host: str, server_id: str | None = None
    ) -> str:
        with self._lock:
            self._validate_code(code, client_host, server_id)
            token = secrets.token_urlsafe(32)
            token_hash = hashlib.sha256(token.encode()).hexdigest()
            self._load()["tokens"][token_hash] = {
                "device_name": device_name,
                "paired_at": int(time.time()),
            }
            self._save()
            self._attempts.pop(client_host, None)
            return token

    def valid_token(self, token: str) -> bool:
        if not token:
            return False
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        with self._lock:
            return any(
                hmac.compare_digest(token_hash, stored)
                for stored in self._load()["tokens"]
            )

    def revoke_all(self) -> None:
        with self._lock:
            self._load()["tokens"] = {}
            self._save()
