"""小型、限速的局域网 UDP 发现；只向请求来源回送公开电脑身份。"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import re
import socket
import time
from collections import deque
from contextlib import suppress
from typing import Any

from app.services.ipv4_networks import LocalIpv4Networks
from app.services.pairing_service import PairingService

__all__ = ["PairingDiscovery"]


class PairingDiscovery:
    app_name = "class_notes_assistant"
    version = 1
    max_request_bytes = 256
    max_response_bytes = 768
    _window_seconds = 2.0
    _max_source_requests = 4
    _max_total_requests = 32
    _max_sources = 128
    _shared_address_space = ipaddress.IPv4Network("100.64.0.0/10")

    def __init__(self, pairing: PairingService, port: int = 48137) -> None:
        self._pairing = pairing
        self._port = port
        self._socket: socket.socket | None = None
        self._task: asyncio.Task[None] | None = None
        self._source_requests: dict[str, deque[float]] = {}
        self._requests: deque[float] = deque()
        self._local_networks = LocalIpv4Networks()

    @property
    def bound_port(self) -> int | None:
        return self._socket.getsockname()[1] if self._socket else None

    async def start(self) -> bool:
        """绑定失败只关闭发现功能，HTTP 服务仍可运行。"""
        if self._socket is not None:
            return True
        listener: socket.socket | None = None
        try:
            listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            listener.setblocking(False)
            listener.bind(("0.0.0.0", self._port))
        except OSError:
            if listener is not None:
                listener.close()
            return False
        self._socket = listener
        self._task = asyncio.create_task(self._serve(listener), name="pairing-discovery")
        return True

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
        if self._socket is not None:
            self._socket.close()
            self._socket = None
        if self._task is not None:
            with suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        self._requests.clear()
        self._source_requests.clear()

    async def _serve(self, listener: socket.socket) -> None:
        loop = asyncio.get_running_loop()
        while True:
            try:
                # 多读一个字节即可识别超限包，不为任意大小的数据报分配缓冲区。
                data, source = await loop.sock_recvfrom(listener, self.max_request_bytes + 1)
                response = self.response_for(data, source[0])
                if response is not None:
                    await loop.sock_sendto(listener, response, source)
            except OSError:
                # 单个不可达的客户端不应终止其他手机的发现。
                if self._socket is None:
                    return
                continue

    def _allow_request(self, host: str) -> bool:
        now = time.monotonic()
        cutoff = now - self._window_seconds
        while self._requests and self._requests[0] <= cutoff:
            self._requests.popleft()
        for source, requests in list(self._source_requests.items()):
            while requests and requests[0] <= cutoff:
                requests.popleft()
            if not requests:
                del self._source_requests[source]
        if len(self._requests) >= self._max_total_requests:
            return False
        requests = self._source_requests.get(host)
        if requests is None:
            if len(self._source_requests) >= self._max_sources:
                return False
            requests = self._source_requests[host] = deque()
        if len(requests) >= self._max_source_requests:
            return False
        requests.append(now)
        self._requests.append(now)
        return True

    def response_for(self, data: bytes, source_host: str) -> bytes | None:
        """严格解析固定协议；请求不能指定回复地址、端口或服务器身份。"""
        if len(data) > self.max_request_bytes:
            return None
        try:
            address = ipaddress.ip_address(source_host)
        except ValueError:
            return None
        if (
            not isinstance(address, ipaddress.IPv4Address)
            or address.is_unspecified
            or address.is_multicast
            or int(address) == 0xFFFFFFFF
        ):
            return None
        if not (
            address.is_private
            or address in self._shared_address_space
            or self._local_networks.contains(address)
        ):
            return None
        if not self._allow_request(source_host):
            return None
        try:
            request: Any = json.loads(data)
        except (ValueError, UnicodeError):
            return None
        if not isinstance(request, dict) or set(request) != {"app", "version", "nonce"}:
            return None
        if request["app"] != self.app_name or type(request["version"]) is not int:
            return None
        nonce = request["nonce"]
        if request["version"] != self.version or not isinstance(nonce, str):
            return None
        if re.fullmatch(r"[0-9a-fA-F]{32}", nonce) is None:
            return None
        response = json.dumps(
            {
                "app": self.app_name,
                "version": self.version,
                "nonce": nonce,
                **self._pairing.public_identity(),
            },
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        return response if len(response) <= self.max_response_bytes else None
