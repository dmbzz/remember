import base64
import hashlib
from pathlib import Path
import pytest
from httpx import ASGITransport, AsyncClient

from app.config import AppConfig
from app.deps import get_config
from app.errors import ApiError
from app.main import create_app
from app.services.note_check_service import NoteCheckRequest, NoteCheckService
from app.services.note_choice_service import ChoiceScope, NoteChoiceRequest, NoteChoiceApply, NoteChoiceService

digest = lambda data: hashlib.sha256(data).hexdigest()


@pytest.fixture
def env(tmp_path):
    root = tmp_path / 'vault'
    directory = root / '课堂笔记' / '物理'
    directory.mkdir(parents=True)
    computer = b'COMPUTER\r\n'
    phone = '\ufeff手机\r\n$u=\\sqrt{2}$\r\n'.encode('utf-8')
    target = directory / '课堂.md'
    target.write_bytes(computer)
    cfg = AppConfig(obsidian_root=str(root), pairing_state_path=str(tmp_path / 'state/pairing.json'))
    service = NoteChoiceService(cfg)
    scope = ChoiceScope(device_id='a'*32, folder_id='b'*64, vault_id=service.vault_id)
    snapshot = NoteCheckRequest(device_id=scope.device_id, folder_id=scope.folder_id, folder_label='课堂笔记',
                               items=[{'path': '物理/课堂.md', 'sha256': digest(phone)}])
    NoteCheckService(cfg).record(snapshot)
    return cfg, scope, target, computer, phone, snapshot


def select(env, source='phone', **overrides):
    cfg, scope, _, computer, phone, _ = env
    values = {**scope.model_dump(), 'path': '物理/课堂.md', 'source': source,
              'phone_hash': digest(phone), 'computer_hash': digest(computer), **overrides}
    return NoteChoiceService(cfg).choose(NoteChoiceRequest(**values))


def apply(env, choice, source='phone', **overrides):
    cfg, scope, _, computer, phone, _ = env
    values = {**scope.model_dump(), 'phone_hash': digest(phone if source == 'phone' else computer),
              **({'content_base64': base64.b64encode(phone).decode()} if source == 'phone' else {}), **overrides}
    return NoteChoiceService(cfg).apply(choice['id'], NoteChoiceApply(**values))


def test_phone_selected_replaces_exact_bytes_without_retained_copy(env):
    cfg, scope, target, computer, phone, _ = env
    choice = select(env)
    assert target.read_bytes() == computer
    assert NoteChoiceService(cfg).list(scope)[0]['status'] == 'pending'
    result = apply(env, choice)
    assert result['status'] == 'completed' and result['selected_hash'] == digest(phone)
    assert target.read_bytes() == phone
    assert list(target.parent.iterdir()) == [target]
    # The decision contains hashes, not losing-version text or base64 content.
    metadata = next(NoteChoiceService(cfg).directory.glob('*.json')).read_text('utf-8')
    assert 'content_base64' not in metadata and base64.b64encode(computer).decode() not in metadata


def test_computer_selection_only_completes_after_phone_confirmation(env):
    _, _, target, computer, _, _ = env
    choice = select(env, 'computer')
    assert target.read_bytes() == computer
    with pytest.raises(ApiError):
        apply(env, choice, 'computer', phone_hash='f'*64)
    assert apply(env, choice, 'computer')['status'] == 'completed'
    assert target.read_bytes() == computer


def test_hash_change_before_selection_or_apply_preserves_new_edit(env):
    _, _, target, _, _, _ = env
    target.write_bytes(b'NEW COMPUTER EDIT')
    with pytest.raises(ApiError):
        select(env)
    target.write_bytes(env[3])
    choice = select(env)
    target.write_bytes(b'EDIT AFTER CHOICE')
    with pytest.raises(ApiError):
        apply(env, choice)
    assert target.read_bytes() == b'EDIT AFTER CHOICE'


def test_phone_changed_after_selection_stops_overwrite(env):
    cfg, scope, target, computer, _, snapshot = env
    choice = select(env)
    snapshot.items[0].sha256 = digest(b'NEW PHONE EDIT')
    NoteCheckService(cfg).record(snapshot)
    with pytest.raises(ApiError):
        apply(env, choice)
    assert target.read_bytes() == computer


def test_scope_switch_and_wrong_vault_cannot_reuse_choice(env):
    cfg, scope, target, computer, _, snapshot = env
    choice = select(env)
    snapshot.folder_id = 'c'*64
    NoteCheckService(cfg).record(snapshot)
    with pytest.raises(ApiError):
        apply(env, choice)
    with pytest.raises(ApiError):
        NoteChoiceService(cfg).list(scope.model_copy(update={'vault_id': 'd'*64}))
    assert target.read_bytes() == computer


def test_idempotent_lost_receipt_never_replaces_subsequent_edit(env):
    _, _, target, _, _, _ = env
    choice = select(env)
    apply(env, choice)
    target.write_bytes(b'SUBSEQUENT EDIT')
    assert apply(env, choice)['status'] == 'completed'
    assert target.read_bytes() == b'SUBSEQUENT EDIT'


def test_crash_after_file_swap_resumes_without_second_overwrite(env, monkeypatch):
    cfg, _, target, _, phone, _ = env
    choice = select(env)
    original = NoteChoiceService._save
    monkeypatch.setattr(NoteChoiceService, '_save', lambda *a: (_ for _ in ()).throw(OSError('receipt disk failure')))
    with pytest.raises(OSError):
        apply(env, choice)
    assert target.read_bytes() == phone
    monkeypatch.setattr(NoteChoiceService, '_save', original)
    assert apply(env, choice)['status'] == 'completed'
    assert list(target.parent.iterdir()) == [target]


def test_corrupt_transport_does_not_touch_original(env):
    _, _, target, computer, _, _ = env
    choice = select(env)
    for encoded in ('not base64!', base64.b64encode(b'OTHER CONTENT').decode()):
        with pytest.raises(ApiError):
            apply(env, choice, content_base64=encoded)
    assert target.read_bytes() == computer and list(target.parent.iterdir()) == [target]


def test_conflicting_pending_choice_rejected_and_reselection_after_reject(env):
    cfg, scope, _, _, _, _ = env
    chosen = select(env)
    assert select(env)['id'] == chosen['id']
    with pytest.raises(ApiError):
        select(env, 'computer')
    NoteChoiceService(cfg).reject(chosen['id'], scope)
    assert select(env, 'computer')['source'] == 'computer'


def test_one_sided_phone_can_create_but_missing_source_cannot_delete(env):
    _, _, target, _, phone, _ = env
    target.unlink()
    with pytest.raises(ApiError):
        select(env, 'computer', computer_hash=None)
    choice = select(env, computer_hash=None)
    apply(env, choice)
    assert target.read_bytes() == phone


@pytest.mark.parametrize('path', ['../a.md', '/a.md', '.hidden.md', '00-说明/a.md', '转写原文/a.md',
                                     '物理\\a.md', 'C:/a.md', '物理/NUL.md', '物理/a.txt'])
def test_path_boundary_and_special_file_rejected(env, path):
    with pytest.raises(ApiError):
        select(env, path=path)
    assert env[2].read_bytes() == env[3]


@pytest.mark.asyncio
async def test_real_routes_report_both_versions_and_lan_auth(env):
    cfg, scope, target, computer, phone, _ = env
    app = create_app()
    app.dependency_overrides[get_config] = lambda: cfg
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        reports = (await client.get('/api/notes/local-checks')).json()['data']['items']
        assert reports[0]['versions']['物理/课堂.md'] == {'phone_hash': digest(phone), 'computer_hash': digest(computer)}
        response = await client.post('/api/notes/file-sync/choices', json={**scope.model_dump(), 'path': '物理/课堂.md',
                         'source': 'phone', 'phone_hash': digest(phone), 'computer_hash': digest(computer)})
        assert response.status_code == 200, response.text
        ident = response.json()['data']['id']
        waiting = await client.get('/api/notes/file-sync/choices', params=scope.model_dump())
        assert waiting.json()['data'][0]['id'] == ident
        response = await client.post(f'/api/notes/file-sync/choices/{ident}/apply', json={**scope.model_dump(),
                          'phone_hash': digest(phone), 'content_base64': base64.b64encode(phone).decode()})
        assert response.status_code == 200, response.text
        assert target.read_bytes() == phone
    async with AsyncClient(transport=ASGITransport(app=app, client=('192.168.137.178', 1000)), base_url='http://test') as client:
        assert (await client.post('/api/notes/file-sync/choices', json={})).status_code == 401
