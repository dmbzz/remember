"""局域网配对与远端访问控制的端到端回归。"""

from __future__ import annotations

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
