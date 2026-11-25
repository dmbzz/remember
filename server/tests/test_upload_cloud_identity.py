from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import threading

from httpx import ASGITransport, AsyncClient
import pytest

from app import config
from app.db.session import Database
from app.deps import get_db
from app.errors import ApiError
from app.main import create_app
from app.services import upload_identity
from app.services.upload_identity import upload_server_id


@pytest.fixture
def cloud_config(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "USER_CONFIG_FILE", tmp_path / "config.user.yaml")
    monkeypatch.setenv("CNA_DEPLOYMENT_MODE", "cloud")
    monkeypatch.setenv("CNA_STORAGE_ROOT", str(tmp_path / "storage"))
    monkeypatch.setenv("CNA_RECORDINGS_ROOT", str(tmp_path / "recordings"))
    monkeypatch.setenv("CNA_AUTH_ENABLED", "true")
    monkeypatch.setenv("CNA_AUTH_TOKEN", "cloud-fixture-token")
    config.reset_app_config()
    return tmp_path


async def test_cloud_upload_identity_retains_bearer_auth_and_survives_app_recreation(cloud_config):
    root = cloud_config
    db = Database("sqlite+aiosqlite:///" + (root / "cloud.db").as_posix())
    await db.create_all()
    app = create_app()

    async def session():
        async with db.session_scope() as value:
            yield value

    app.dependency_overrides[get_db] = session
    data = b"cloud fixture audio"
    params = {"sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data)}
    headers = {"Authorization": "Bearer cloud-fixture-token"}
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="https://cloud.invalid") as client:
            assert (await client.get("/api/pairing/check")).status_code == 401
            assert (await client.get("/api/pairing/check", headers={"Authorization":"Bearer wrong"})).status_code == 401
            check = await client.get("/api/pairing/check", headers=headers)
            assert check.status_code == 200, check.text
            identity = check.json()["data"]["server_id"]
            course = (await client.post("/api/courses/init-defaults", headers=headers)).json()["data"][0]
            rec = (await client.post("/api/recordings", headers=headers, json={
                "course_id":course["id"], "codec":"wav", "size_bytes":len(data),
            })).json()["data"]
            rid = rec["id"]
            assert (await client.post(f"/api/recordings/{rid}/upload-file", headers=headers,
                                      files={"file":("fixture.wav", data)})).status_code == 200
            assert (await client.get(f"/api/recordings/{rid}/receipt", params=params)).status_code == 401
            receipt = (await client.get(f"/api/recordings/{rid}/receipt", headers=headers, params=params)).json()["data"]
            assert receipt["verified"] and receipt["server_id"] == identity
            for method, path, body in (
                ("GET", "/api/pairing/info", None),
                ("GET", "/api/pairing/identity", None),
                ("POST", "/api/pairing/exchange", {"code":"000000"}),
                ("POST", "/api/pairing/resolve", {"code":"000000"}),
                ("POST", "/api/pairing/revoke-all", None),
            ):
                response = await client.request(method, path, headers=headers, json=body)
                assert response.status_code == 404, response.text
        async with AsyncClient(transport=ASGITransport(app=create_app()), base_url="https://cloud.invalid") as restarted:
            response = await restarted.get("/api/pairing/check", headers=headers)
            assert response.json()["data"]["server_id"] == identity
        assert json.loads((root / "storage/server-identity.json").read_text("utf-8")) == {"server_id":identity}
    finally:
        await db.dispose()


def test_concurrent_cloud_identity_initialization_selects_one_durable_identity(cloud_config):
    app = create_app()
    ready = threading.Barrier(8)

    def initialize(_):
        ready.wait(timeout=10)
        return upload_server_id(app)

    with ThreadPoolExecutor(max_workers=8) as pool:
        identities = list(pool.map(initialize, range(8)))
    assert len(set(identities)) == 1
    assert upload_server_id(create_app()) == identities[0]
    assert not list((cloud_config / "storage").glob(".server-identity-*.tmp"))


@pytest.mark.parametrize("contents", ["{broken", '[]', '{"server_id":"invalid"}'])
def test_corrupt_cloud_identity_fails_closed_without_replacement(cloud_config, contents):
    path = cloud_config / "storage/server-identity.json"
    path.parent.mkdir()
    path.write_text(contents, encoding="utf-8")
    with pytest.raises(ApiError):
        upload_server_id(create_app())
    assert path.read_text("utf-8") == contents


def test_failed_atomic_identity_publish_does_not_return_unpersisted_id(cloud_config, monkeypatch):
    def unavailable_link(*args):
        raise OSError("simulated storage unavailable")

    monkeypatch.setattr(upload_identity.os, "link", unavailable_link)
    with pytest.raises(ApiError):
        upload_server_id(create_app())
    assert not (cloud_config / "storage/server-identity.json").exists()
    assert not list((cloud_config / "storage").glob(".server-identity-*.tmp"))
