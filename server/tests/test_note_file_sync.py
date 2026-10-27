import base64
import hashlib
from pathlib import Path
import pytest
from httpx import AsyncClient, ASGITransport
from app.config import AppConfig
from app.deps import get_config
from app.main import create_app
from app.errors import ApiError
from app.services.note_file_sync_service import NoteFileSyncService


def fixture(tmp_path):
    root = tmp_path / 'vault'
    folder = root / '课堂笔记' / '物理'
    folder.mkdir(parents=True)
    data = '\ufeff原文\r\n公式 $u_1(t) = \\sqrt{2}U_1\\sin(\\omega t)$\r\n'.encode('utf-8')
    (folder / '力.md').write_bytes(data)
    cfg = AppConfig(obsidian_root=str(root), pairing_state_path=str(tmp_path / 'pairing.json'))
    return cfg, folder, data


def test_byte_transport_and_readonly(tmp_path):
    cfg, folder, data = fixture(tmp_path)
    svc = NoteFileSyncService(cfg)
    manifest = svc.manifest()
    result = svc.content('物理/力.md', manifest['items'][0]['sha256'], manifest['vault_id'])
    assert base64.b64decode(result['content_base64']) == data
    assert (folder / '力.md').read_bytes() == data
    assert result['bytes'] == len(data)
    (folder / '.cna-sync-old-test.md').write_bytes(b'backup')
    assert len(svc.manifest()['items']) == 1


def test_stale_manifest_and_vault_change_fail_closed(tmp_path):
    cfg, folder, data = fixture(tmp_path)
    svc = NoteFileSyncService(cfg)
    manifest = svc.manifest()
    (folder / '力.md').write_bytes(b'updated')
    with pytest.raises(ApiError): svc.content('物理/力.md', manifest['items'][0]['sha256'], manifest['vault_id'])
    with pytest.raises(ApiError): svc.content('物理/力.md', hashlib.sha256(b'updated').hexdigest(), 'b'*64)


@pytest.mark.parametrize('path', ['../outside.md', '物理/../../x.md', '/x.md', '物理\\力.md', '物理/.private.md', '00-教材/x.md', '转写原文/x.md', 'a.txt', 'c:/x.md'])
def test_path_boundaries(tmp_path, path):
    cfg, _, data = fixture(tmp_path)
    svc = NoteFileSyncService(cfg)
    with pytest.raises(ApiError): svc.content(path, hashlib.sha256(data).hexdigest(), svc.vault_id)


def test_missing_vault_is_not_empty_success(tmp_path):
    cfg = AppConfig(obsidian_root=str(tmp_path / 'missing'))
    with pytest.raises(ApiError): NoteFileSyncService(cfg).manifest()


@pytest.mark.asyncio
async def test_endpoints_and_lan_auth(tmp_path, monkeypatch):
    cfg, folder, data = fixture(tmp_path)
    monkeypatch.setattr('app.main.get_app_config', lambda: cfg)
    app = create_app(); app.dependency_overrides[get_config] = lambda: cfg
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        response = await client.get('/api/notes/file-sync/manifest')
        assert response.status_code == 200, response.text
        manifest = response.json()['data']
        result = await client.get('/api/notes/file-sync/content', params={'path': '物理/力.md', 'sha256': manifest['items'][0]['sha256'], 'vault_id': manifest['vault_id']})
        assert result.status_code == 200, result.text
        assert base64.b64decode(result.json()['data']['content_base64']) == data
    async with AsyncClient(transport=ASGITransport(app=app, client=('192.168.137.178', 10000)), base_url='http://test') as client:
        assert (await client.get('/api/notes/file-sync/manifest')).status_code == 401
