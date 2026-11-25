"""局域网配对与远端访问控制的端到端回归。"""

from __future__ import annotations

import hashlib
import hmac
import json
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from app.config import reset_app_config
from app.main import create_app
from app.services.pairing_service import PairingError, PairingService


@pytest.mark.asyncio
async def test_phone_must_pair_before_access_and_can_be_revoked(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setenv("CNA_PAIRING_STATE_PATH", str(tmp_path / "pairing.json"))
    reset_app_config()
    app = create_app()

    local_transport = ASGITransport(app=app, client=("127.0.0.1", 10001))
    remote_transport = ASGITransport(app=app, client=("192.168.1.20", 10002))
    async with AsyncClient(transport=local_transport, base_url="http://pc") as local, \
            AsyncClient(transport=remote_transport, base_url="http://pc") as phone:
        info = await local.get("/api/pairing/info")
        assert info.status_code == 200
        pin = info.json()["data"]["code"]
        assert len(pin) == 6 and pin.isdigit()

        assert (await phone.get("/api/pairing/info")).status_code == 403
        assert (await phone.get("/api/pairing/check")).status_code == 401
        assert (await phone.get("/docs")).status_code == 401
        wrong = await phone.post(
            "/api/pairing/exchange", json={"code": "000000", "device_name": "测试手机"}
        )
        if pin != "000000":
            assert wrong.status_code == 403

        paired = await phone.post(
            "/api/pairing/exchange", json={"code": pin, "device_name": "测试手机"}
        )
        assert paired.status_code == 200
        token = paired.json()["data"]["token"]
        assert len(token) >= 32
        authorized = await phone.get(
            "/api/pairing/check", headers={"Authorization": f"Bearer {token}"}
        )
        assert authorized.status_code == 200

        # 令牌重启后可用，但可以在电脑本机一键撤销。
        persisted = PairingService(tmp_path / "pairing.json", port=8000)
        assert persisted.valid_token(token)
        assert (await local.post("/api/pairing/revoke-all")).status_code == 200
        assert (await phone.get(
            "/api/pairing/check", headers={"Authorization": f"Bearer {token}"}
        )).status_code == 401


def test_pairing_code_expires_and_guesses_are_limited(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    service = PairingService(tmp_path / "pairing.json", port=8000)
    monkeypatch.setattr("app.services.pairing_service.time.time", lambda: 1200.0)
    pin = service.info()["code"]
    monkeypatch.setattr("app.services.pairing_service.time.time", lambda: 1800.0)
    with pytest.raises(PairingError, match="过期"):
        service.exchange(pin, "手机", "192.168.1.20")
    for _ in range(4):
        with pytest.raises(PairingError):
            service.exchange(pin, "手机", "192.168.1.20")
    with pytest.raises(PairingError) as error:
        service.exchange(pin, "手机", "192.168.1.20")
    assert error.value.status_code == 429


def test_public_identity_and_legacy_credentials_survive_upgrade(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    state_path = tmp_path / "pairing.json"
    token = "previous-device-token"
    secret = "ab" * 32
    state_path.write_text(json.dumps({
        "secret": secret,
        "tokens": {hashlib.sha256(token.encode()).hexdigest(): {"device_name": "旧手机"}},
    }), encoding="utf-8")
    before = state_path.read_bytes()
    monkeypatch.setattr("app.services.pairing_service.time.time", lambda: 1200.0)
    monkeypatch.setattr("app.services.pairing_service.socket.gethostname", lambda: "电脑" * 40)
    monkeypatch.setattr(PairingService, "lan_addresses", staticmethod(lambda: ["192.168.1.3"]))
    digest = hmac.new(bytes.fromhex(secret), b"2", hashlib.sha256).digest()
    legacy_pin = f"{int.from_bytes(digest[:8], 'big') % 1_000_000:06d}"

    service = PairingService(state_path, port=18000)
    info = service.info()
    assert info["code"] == legacy_pin
    assert info["connection_codes"] == [f"192.168.1.3:18000#{legacy_pin}"]
    assert len(info["name"]) == 64
    assert len(info["server_id"]) == 16
    assert service.valid_token(token)
    assert PairingService(state_path, 18000).public_identity() == service.public_identity()
    assert state_path.read_bytes() == before


def test_resolve_does_not_issue_or_persist_tokens(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    service = PairingService(tmp_path / "pairing.json", port=8000)
    info = service.info()
    existing_token = service.exchange(info["code"], "原手机", "192.168.1.10")
    before = (tmp_path / "pairing.json").read_bytes()

    def unexpected_write(*args, **kwargs):
        pytest.fail("resolve must not save pairing state")

    monkeypatch.setattr(service, "_save", unexpected_write)
    monkeypatch.setattr("app.services.pairing_service.secrets.token_urlsafe", unexpected_write)
    identity = service.resolve(info["code"], "192.168.1.20", info["server_id"])
    assert set(identity) == {"server_id", "name", "port"}
    assert identity["server_id"] == info["server_id"]
    assert service.valid_token(existing_token)
    assert service.info()["paired_devices"] == 1
    assert (tmp_path / "pairing.json").read_bytes() == before


def test_correct_probes_after_four_errors_leave_exchange_available(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setattr("app.services.pairing_service.time.monotonic", lambda: 1000.0)
    service = PairingService(tmp_path / "pairing.json", port=8000)
    info = service.info()
    wrong = "000000" if info["code"] != "000000" else "000001"
    host = "192.168.1.20"
    for operation in [service.resolve, lambda code, source: service.exchange(code, "手机", source)] * 2:
        with pytest.raises(PairingError) as error:
            operation(wrong, host)
        assert error.value.status_code == 403
    for _ in range(8):
        assert service.resolve(info["code"], host)["server_id"] == info["server_id"]
    token = service.exchange(info["code"], "手机", host, info["server_id"])
    assert service.valid_token(token)


def test_resolve_and_exchange_share_error_limit_and_it_expires(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    clock = [1000.0]
    monkeypatch.setattr("app.services.pairing_service.time.monotonic", lambda: clock[0])
    service = PairingService(tmp_path / "pairing.json", port=8000)
    info = service.info()
    wrong_id = "0" * 16 if info["server_id"] != "0" * 16 else "1" * 16
    for _ in range(5):
        with pytest.raises(PairingError) as error:
            service.resolve(info["code"], "192.168.1.20", wrong_id)
        assert error.value.status_code == 403
    for operation in [service.resolve, lambda code, source: service.exchange(code, "手机", source)]:
        with pytest.raises(PairingError) as error:
            operation(info["code"], "192.168.1.20")
        assert error.value.status_code == 429
    assert service.resolve(info["code"], "192.168.1.21")["port"] == 8000
    clock[0] += 301
    assert service.valid_token(service.exchange(info["code"], "手机", "192.168.1.20"))


@pytest.mark.asyncio
async def test_anonymous_resolve_identity_check_and_old_exchange_request(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setenv("CNA_PAIRING_STATE_PATH", str(tmp_path / "pairing.json"))
    reset_app_config()
    app = create_app()
    transport = ASGITransport(app=app, client=("192.168.1.20", 10002))
    info = app.state.pairing_service.info()
    before = (tmp_path / "pairing.json").read_bytes()
    async with AsyncClient(transport=transport, base_url="http://pc") as phone:
        resolved = await phone.post("/api/pairing/resolve", json={"code": info["code"]})
        assert resolved.status_code == 200
        assert set(resolved.json()["data"]) == {"server_id", "name", "port"}
        assert (tmp_path / "pairing.json").read_bytes() == before
        assert (await phone.get("/api/pairing/check")).status_code == 401
        for payload in [
            {"code": info["code"], "host": "http://other-host"},
            {"code": "１２３４５６"},
            {"code": info["code"], "server_id": "invalid"},
        ]:
            assert (await phone.post("/api/pairing/resolve", json=payload)).status_code == 422
        wrong_id = "0" * 16 if info["server_id"] != "0" * 16 else "1" * 16
        wrong_computer = await phone.post("/api/pairing/exchange", json={
            "code": info["code"], "server_id": wrong_id,
        })
        assert wrong_computer.status_code == 403
        assert app.state.pairing_service.info()["paired_devices"] == 0
        # 兼容已安装版本：不传 server_id 的旧交换请求仍然可用。
        paired = await phone.post("/api/pairing/exchange", json={"code": info["code"]})
        assert paired.status_code == 200
        assert app.state.pairing_service.valid_token(paired.json()["data"]["token"])


def test_resolve_also_rejects_expired_code(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    service = PairingService(tmp_path / "pairing.json", port=8000)
    monkeypatch.setattr("app.services.pairing_service.time.time", lambda: 1200.0)
    info = service.info()
    monkeypatch.setattr("app.services.pairing_service.time.time", lambda: 1800.0)
    with pytest.raises(PairingError, match="过期"):
        service.resolve(info["code"], "192.168.1.20", info["server_id"])


@pytest.mark.asyncio
async def test_anonymous_identity_has_no_credentials_and_leaves_existing_pairing_unchanged(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    path = tmp_path / "pairing.json"
    monkeypatch.setenv("CNA_PAIRING_STATE_PATH", str(path))
    reset_app_config()
    app = create_app()
    service = app.state.pairing_service
    info = service.info()
    token = service.exchange(info["code"], "已有手机", "192.168.1.10")
    before = path.read_bytes()

    def unexpected_save():
        pytest.fail("identity must not persist a change to existing pairing state")

    monkeypatch.setattr(service, "_save", unexpected_save)
    transport = ASGITransport(app=app, client=("192.168.1.20", 10002))
    async with AsyncClient(transport=transport, base_url="http://pc") as phone:
        # 多个地址可先归并身份，不需要 PIN 且不消耗错误尝试次数。
        for _ in range(8):
            response = await phone.get("/api/pairing/identity")
            assert response.status_code == 200
            assert response.json()["data"] == service.public_identity()
            assert set(response.json()["data"]) == {"server_id", "name", "port"}
            assert token not in response.text
        assert not service._attempts
        assert (await phone.get("/api/pairing/check")).status_code == 401
        assert (await phone.get("/api/pairing/check", headers={
            "Authorization": f"Bearer {token}",
        })).status_code == 200
    assert path.read_bytes() == before
    assert service.info()["paired_devices"] == 1
    assert service.valid_token(token)
