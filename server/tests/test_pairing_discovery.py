"""发现协议的包大小、限流、凭据隔离与真实本机 UDP 生命周期。"""

from __future__ import annotations

import asyncio
import json
import socket
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from httpx import ASGITransport, AsyncClient

import app.main as main_module
from app.config import get_app_config, reset_app_config
from app.main import create_app
from app.services.pairing_discovery import PairingDiscovery
from app.services.pairing_service import PairingService


def discovery_request(**updates) -> bytes:
    return json.dumps({
        "app": "class_notes_assistant", "version": 1, "nonce": "12ab" * 8, **updates,
    }).encode()


def test_discovery_echoes_nonce_and_only_public_identity(tmp_path: Path):
    pairing = PairingService(tmp_path / "pairing.json", 18000)
    info = pairing.info()
    token = pairing.exchange(info["code"], "已有手机", "192.168.1.21")
    state_before = (tmp_path / "pairing.json").read_bytes()
    discovery = PairingDiscovery(pairing)
    response_bytes = discovery.response_for(discovery_request(), "192.168.1.20")
    assert response_bytes is not None
    response = json.loads(response_bytes)
    assert response == {
        "app": "class_notes_assistant", "version": 1, "nonce": "12ab" * 8,
        **pairing.public_identity(),
    }
    assert len(response_bytes) <= discovery.max_response_bytes
    assert not {"code", "token", "secret", "tokens", "addresses", "connection_codes"} & response.keys()
    assert token.encode() not in response_bytes
    assert (tmp_path / "pairing.json").read_bytes() == state_before


@pytest.mark.parametrize("data", [
    b"x" * 257,
    b"not-json",
    b"\xff",
    b"[]",
    b"null",
    discovery_request(app="other-app"),
    discovery_request(version=2),
    discovery_request(version=True),
    discovery_request(nonce="ab"),
    discovery_request(nonce="z" * 32),
    discovery_request(nonce=123),
    discovery_request(host="192.168.1.99"),
    discovery_request(port=12345),
])
def test_discovery_rejects_malformed_and_redirected_requests(tmp_path: Path, data: bytes):
    path = tmp_path / "pairing.json"
    discovery = PairingDiscovery(PairingService(path, 8000))
    assert discovery.response_for(data, "192.168.1.20") is None
    assert not path.exists()


@pytest.mark.parametrize("host", ["8.8.8.8", "0.0.0.0", "224.0.0.1", "::1", "bad-host"])
def test_discovery_responds_only_to_lan_ipv4(
    tmp_path: Path, host: str, monkeypatch: pytest.MonkeyPatch
):
    discovery = PairingDiscovery(PairingService(tmp_path / "pairing.json", 8000))
    monkeypatch.setattr(discovery._local_networks, "contains", lambda address: False)
    assert discovery.response_for(discovery_request(), host) is None


def test_discovery_limits_each_source_and_total_requests(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    clock = [1000.0]
    monkeypatch.setattr("app.services.pairing_discovery.time.monotonic", lambda: clock[0])
    discovery = PairingDiscovery(PairingService(tmp_path / "pairing.json", 8000))
    request = discovery_request()
    for _ in range(discovery._max_source_requests):
        assert discovery.response_for(request, "192.168.1.20") is not None
    assert discovery.response_for(request, "192.168.1.20") is None
    for index in range(discovery._max_total_requests - discovery._max_source_requests):
        assert discovery.response_for(request, f"192.168.2.{index + 1}") is not None
    assert discovery.response_for(request, "192.168.3.1") is None
    assert len(discovery._source_requests) <= discovery._max_sources
    clock[0] += discovery._window_seconds + 0.01
    assert discovery.response_for(request, "192.168.1.20") is not None
    assert list(discovery._source_requests) == ["192.168.1.20"]


@pytest.mark.asyncio
async def test_udp_socket_reply_and_shutdown(tmp_path: Path):
    discovery = PairingDiscovery(PairingService(tmp_path / "pairing.json", 18000), port=0)
    assert await discovery.start()
    bound_port = discovery.bound_port
    assert bound_port is not None
    client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    client.setblocking(False)
    try:
        loop = asyncio.get_running_loop()
        await loop.sock_sendto(client, discovery_request(), ("127.0.0.1", bound_port))
        payload, source = await asyncio.wait_for(loop.sock_recvfrom(client, 1024), timeout=2)
        assert source[1] == bound_port
        assert json.loads(payload)["port"] == 18000
    finally:
        client.close()
        await discovery.stop()
    assert discovery.bound_port is None
    assert discovery._task is None
    assert not discovery._source_requests
    # 关闭后同端口可重新绑定，避免重启残留占用。
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as replacement:
        replacement.bind(("127.0.0.1", bound_port))


@pytest.mark.asyncio
async def test_bind_failure_does_not_prevent_http_health(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    # 真正进入应用生命周期，但 DB / 队列 / 模型后台操作全部替换为隔离替身。
    database = SimpleNamespace(create_all=AsyncMock(), dispose=AsyncMock())
    queue = SimpleNamespace(start=AsyncMock(), stop=AsyncMock(), worker_count=1)
    dispatcher = SimpleNamespace(start=AsyncMock(), stop=AsyncMock())
    monkeypatch.setattr(main_module, "get_database", lambda: database)
    monkeypatch.setattr(main_module, "get_task_queue", lambda: queue)
    monkeypatch.setattr(main_module, "AsrDispatcher", lambda database: dispatcher)
    monkeypatch.setattr("app.services.asr_model_manager.stop_model_operations", lambda: None)
    monkeypatch.setenv("CNA_PAIRING_STATE_PATH", str(tmp_path / "pairing.json"))
    monkeypatch.setenv("CNA_PAIRING_DISCOVERY_ENABLED", "true")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as occupied:
        occupied.bind(("0.0.0.0", 0))
        monkeypatch.setenv("CNA_PAIRING_DISCOVERY_PORT", str(occupied.getsockname()[1]))
        reset_app_config()
        app = create_app()
        async with app.router.lifespan_context(app):
            assert app.state.pairing_discovery.bound_port is None
            transport = ASGITransport(app=app, client=("127.0.0.1", 12345))
            async with AsyncClient(transport=transport, base_url="http://pc") as client:
                assert (await client.get("/api/health")).status_code == 200
        assert app.state.pairing_discovery._task is None
    database.create_all.assert_awaited_once()
    database.dispose.assert_awaited_once()
    queue.stop.assert_awaited_once()
    dispatcher.stop.assert_awaited_once()
    assert not (tmp_path / "pairing.json").exists()


def test_discovery_environment_configuration_and_cloud_disabled(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setenv("CNA_PAIRING_STATE_PATH", str(tmp_path / "pairing.json"))
    monkeypatch.setenv("CNA_PAIRING_DISCOVERY_PORT", "48138")
    monkeypatch.setenv("CNA_PAIRING_DISCOVERY_ENABLED", "false")
    reset_app_config()
    assert get_app_config().pairing_discovery_port == 48138
    assert not hasattr(create_app().state, "pairing_discovery")
    monkeypatch.setenv("CNA_PAIRING_DISCOVERY_ENABLED", "true")
    reset_app_config()
    assert create_app().state.pairing_discovery._port == 48138
    monkeypatch.setenv("CNA_DEPLOYMENT_MODE", "cloud")
    reset_app_config()
    app = create_app()
    assert not hasattr(app.state, "pairing_discovery")
    assert not hasattr(app.state, "pairing_service")
    assert not (tmp_path / "pairing.json").exists()


@pytest.mark.asyncio
async def test_cloud_does_not_expose_resolve(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("CNA_DEPLOYMENT_MODE", "cloud")
    monkeypatch.setenv("CNA_AUTH_ENABLED", "false")
    monkeypatch.setenv("CNA_PAIRING_STATE_PATH", str(tmp_path / "pairing.json"))
    reset_app_config()
    transport = ASGITransport(app=create_app(), client=("192.168.1.20", 10002))
    async with AsyncClient(transport=transport, base_url="http://pc") as client:
        response = await client.post("/api/pairing/resolve", json={"code": "123456"})
        assert response.status_code == 404
        assert (await client.get("/api/pairing/identity")).status_code == 404
    assert not (tmp_path / "pairing.json").exists()
