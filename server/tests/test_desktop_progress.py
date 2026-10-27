import json
from pathlib import Path
from types import SimpleNamespace
import pytest
from app import config
from app.services import desktop_notifications as notifications
from app.services import asr_progress
from app.services.upload_progress import UploadProgressMiddleware, reception_progress, active_uploads
from tests.test_asr_upload import env, upload
from app.services import asr_jobs
from sqlalchemy import select
from app.db.models import AsrJob
from app.services import atomic_files

def test_atomic_receipt_retries_only_transient_windows_replace_failure(tmp_path, monkeypatch):
    target = tmp_path / 'receipt.json'
    target.write_text('{"old":true}', 'utf-8')
    original = Path.replace
    attempts = []
    def replace(path, destination):
        attempts.append(destination)
        if len(attempts) == 1:
            error = PermissionError('simulated Windows sharing conflict')
            error.winerror = 5
            raise error
        return original(path, destination)
    monkeypatch.setattr(Path, 'replace', replace)
    atomic_files.atomic_json(target, {'new':True})
    assert json.loads(target.read_text('utf-8')) == {'new':True}
    assert len(attempts) == 2

def test_progress_write_failure_does_not_abort_inference(tmp_path, monkeypatch):
    def denied(*args): raise PermissionError('progress locked')
    monkeypatch.setattr(asr_progress, 'atomic_json', denied)
    asr_progress.update_progress(tmp_path, 'loading', generation=0)
    job = SimpleNamespace(id='job', run_generation=0, status='running')
    assert asr_progress.read_progress(job, tmp_path)['phase'] == 'preparing'

@pytest.mark.asyncio
async def test_desktop_notifications_opt_in_roundtrip_and_local_only(env):
    client, db, dispatcher, cfg, cid = env
    old = (config.USER_CONFIG_FILE.parent / 'asr.user.json').read_bytes()
    assert (await client.get('/api/settings/desktop')).json()['data'] == {'asr_notifications': False}
    assert (await client.put('/api/settings/desktop', json={'asr_notifications': True})).json()['data']['asr_notifications'] is True
    assert (await client.get('/api/settings/desktop')).json()['data']['asr_notifications'] is True
    assert (await client.put('/api/settings/desktop', json={'asr_notifications': False})).status_code == 200
    assert (config.USER_CONFIG_FILE.parent / 'asr.user.json').read_bytes() == old
    assert (await client.put('/api/settings/desktop', json={'asr_notifications': True, 'other': 1})).status_code == 422

@pytest.mark.asyncio
async def test_asr_notifications_only_at_actual_lifecycle_boundaries(env, monkeypatch):
    client, db, dispatcher, cfg, cid = env
    events = []
    monkeypatch.setattr(asr_jobs, 'notify_asr', lambda event, source: events.append(event))
    monkeypatch.setattr(asr_jobs, 'infer', lambda *args: {'duration': 90, 'segments': [{'s':0, 'e':90, 't':'学' * 1600}],
        'aligned':True, 'coverage_complete':True, 'engine':'Qwen', 'elapsed_sec':1})
    await upload(env)
    async with db.session_scope() as session:
        job = (await session.scalars(select(AsrJob))).first()
        ident = job.id
    await dispatcher.execute(ident)
    assert events == ['started', 'completed']
    await client.get('/api/asr/jobs')
    await client.get('/api/asr/jobs')
    assert events == ['started', 'completed']

def test_notifications_disabled_makes_no_process(tmp_path, monkeypatch):
    monkeypatch.setattr(config, 'USER_CONFIG_FILE', tmp_path / 'config.yaml')
    monkeypatch.setattr(notifications.subprocess, 'run', lambda *a, **k: pytest.fail('Disabled notification ran a process'))
    notifications.notify_asr('started', 'course.wav')
    assert not (tmp_path / 'desktop.user.json').exists()

def test_enabled_notification_uses_own_hidden_helper_and_tolerates_system_denial(tmp_path, monkeypatch):
    monkeypatch.setattr(config, 'USER_CONFIG_FILE', tmp_path / 'config.yaml')
    monkeypatch.setattr(notifications, '__file__', str(tmp_path / 'backend/server/app/services/desktop_notifications.py'))
    (tmp_path / 'app.exe').write_bytes(b'not executed')
    notifications.save_desktop_settings(notifications.DesktopSettings(asr_notifications=True))
    calls = []
    def run(args, **kwargs):
        calls.append((args, kwargs))
        return SimpleNamespace(returncode=2)
    monkeypatch.setattr(notifications.subprocess, 'run', run)
    notifications.notify_asr('completed', '线性代数_20261021.m4a')
    assert len(calls) == 1
    assert calls[0][0][:2] == [str(tmp_path / 'app.exe'), '--asr-notification']
    assert '线性代数' in calls[0][0][-1]
    assert calls[0][1]['creationflags'] == notifications.subprocess.CREATE_NO_WINDOW

def test_progress_generation_and_terminal_state(tmp_path):
    work = tmp_path / 'job'; work.mkdir()
    job = SimpleNamespace(id='job', run_generation=2, status='running')
    asr_progress.update_progress(work, 'transcribing', 1, 5, generation=2)
    assert asr_progress.read_progress(job, tmp_path)['completed_chunks'] == 1
    job.run_generation = 3
    assert asr_progress.read_progress(job, tmp_path)['phase'] == 'preparing'
    job.status = 'completed'
    assert asr_progress.read_progress(job, tmp_path)['phase'] == 'completed'

@pytest.mark.asyncio
async def test_upload_counts_actual_body_and_preserves_messages():
    active_uploads.clear()
    chunks = [{'type': 'http.request', 'body': b'1234', 'more_body': True},
              {'type': 'http.request', 'body': b'567890', 'more_body': False}]
    rec = SimpleNamespace(id='rec_probe', upload_status='pending', size_bytes=10)
    async def receive(): return chunks.pop(0)
    sent = []
    async def send(message): sent.append(message)
    async def app(scope, receive, send):
        first = await receive()
        assert first['body'] == b'1234'
        assert reception_progress(rec)['received_bytes'] == 4
        assert reception_progress(rec)['phase'] == 'receiving'
        await receive()
        assert reception_progress(rec)['phase'] == 'saving'
        await send({'type':'http.response.start', 'status':200, 'headers':[]})
        await send({'type':'http.response.body', 'body':b'ok'})
    await UploadProgressMiddleware(app)({'type':'http','method':'POST', 'path':'/api/recordings/rec_probe/upload-file', 'headers':[(b'content-length',b'10')]}, receive, send)
    assert reception_progress(rec)['received_bytes'] == 10
    assert sent[-1]['body'] == b'ok'
    rec.upload_status='uploaded'
    assert reception_progress(rec)['phase'] == 'received'
    active_uploads.clear()

@pytest.mark.asyncio
async def test_upload_disconnect_never_claims_success():
    active_uploads.clear()
    messages=[{'type':'http.request', 'body':b'12', 'more_body':True}, {'type':'http.disconnect'}]
    async def receive(): return messages.pop(0)
    async def send(value): pass
    async def app(scope, receive, send): await receive(); await receive()
    await UploadProgressMiddleware(app)({'type':'http', 'method':'POST','path':'/api/recordings/probe/upload-file','headers':[]},receive,send)
    assert active_uploads['probe']['phase'] == 'interrupted'
    active_uploads.clear()
