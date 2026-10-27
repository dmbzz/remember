import hashlib
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError

from app.config import AppConfig
from app.deps import get_config
from app.errors import ApiError
from app.main import create_app
from app.services.note_check_service import NoteCheckRequest, NoteCheckService


def setup(tmp_path):
    root = tmp_path / 'vault'
    folder = root / '课堂笔记'
    (folder / '物理').mkdir(parents=True)
    (folder / '物理' / '相同.md').write_bytes(b'same')
    (folder / '物理' / '不同.md').write_bytes(b'computer')
    (folder / '物理' / '电脑.md').write_bytes(b'new')
    cfg = AppConfig(obsidian_root=str(root), pairing_state_path=str(tmp_path / 'appdata' / 'pairing.json'))
    items = [{'path': f'物理/{name}.md', 'sha256': hashlib.sha256(text).hexdigest()} for name, text in [('相同', b'same'), ('不同', b'phone'), ('手机', b'only')]]
    return cfg, NoteCheckRequest(device_id='a'*32, folder_label='课堂笔记', items=items), folder


def test_diff_persist_recompute_and_no_note_writes(tmp_path):
    cfg, request, folder = setup(tmp_path)
    original = {f: f.read_bytes() for f in folder.rglob('*.md')}
    result = NoteCheckService(cfg).record(request)
    assert result['same'] == 1
    assert result['only_on_phone'] == ['物理/手机.md']
    assert result['only_on_computer'] == ['物理/电脑.md']
    assert result['different'] == ['物理/不同.md']
    assert original == {f: f.read_bytes() for f in folder.rglob('*.md')}
    assert NoteCheckService(cfg).reports()[0]['phone_checked_at'] == result['phone_checked_at']
    (folder / '物理' / '相同.md').write_bytes(b'edited')
    recomputed = NoteCheckService(cfg).reports()[0]
    assert recomputed['same'] == 0
    assert '物理/相同.md' in recomputed['different']
    other = AppConfig(obsidian_root=str(tmp_path / 'other'), pairing_state_path=cfg.pairing_state_path)
    (Path(other.obsidian_root) / '课堂笔记').mkdir(parents=True)
    assert NoteCheckService(other).reports() == []


def test_filter_and_missing_directory_are_not_empty_success(tmp_path):
    cfg, request, folder = setup(tmp_path)
    for path in ['00-说明.md', '.隐藏.md', '物理/转写原文/原文.md', '.cache/a.md', '00-教材/a.md']:
        file = folder / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(b'excluded')
    result = NoteCheckService(cfg).record(request)
    assert result['computer_total'] == 3
    cfg.obsidian_root = str(tmp_path / 'missing')
    with pytest.raises(ApiError):
        NoteCheckService(cfg).record(request)


@pytest.mark.parametrize('items', [
    [{'path': '../outside.md', 'sha256': 'a'*64}],
    [{'path': 'a.md', 'sha256': 'bad'}],
    [{'path': 'a.md', 'sha256': 'a'*64}]*2,
])
def test_invalid_snapshot_rejected(items):
    with pytest.raises(ValidationError):
        NoteCheckRequest(device_id='a'*32, folder_label='notes', items=items)


@pytest.mark.asyncio
async def test_actual_api_contract(tmp_path):
    cfg, request, _ = setup(tmp_path)
    app = create_app()
    app.dependency_overrides[get_config] = lambda: cfg
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        response = await client.post('/api/notes/local-checks', json=request.model_dump())
        assert response.status_code == 200, response.text
        assert response.json()['data']['same'] == 1
        reports = await client.get('/api/notes/local-checks')
        assert reports.json()['data']['items'][0]['device_id'] == request.device_id
        invalid = request.model_dump()
        invalid['unexpected'] = True
        assert (await client.post('/api/notes/local-checks', json=invalid)).status_code == 422
