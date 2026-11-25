from pathlib import Path
import asyncio
import json
import threading
import sys
import os

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app import config
from app.db.models import AsrJob, Recording
from app.db.session import Database
from app.deps import get_db
from app.main import create_app
from app.services import asr_archive, asr_jobs
from app.services.asr_engine import sha256
from app.services.asr_jobs import AsrDispatcher
from app.services.asr_settings import AsrSettings, load_settings, save_settings


@pytest.fixture
async def env(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "USER_CONFIG_FILE", tmp_path / "config.user.yaml")
    output = tmp_path / "output"
    output.mkdir()
    cfg = AsrSettings(enabled=True, mode="local_qwen", output_dir=str(output), base_url="http://localhost:9944/v1", delete_source=True,
                      python_path=sys.executable, ffmpeg_path=sys.executable, model_path=str(output), aligner_path=str(output))
    save_settings(cfg)
    db = Database("sqlite+aiosqlite:///" + (tmp_path / "asr.db").as_posix())
    await db.create_all()
    app = create_app()
    async def session():
        async with db.session_scope() as s:
            yield s
    app.dependency_overrides[get_db] = session
    dispatcher = AsrDispatcher(db, tmp_path / "work")
    app.state.asr_dispatcher = dispatcher
    async with AsyncClient(transport=ASGITransport(app=app, client=("127.0.0.1", 12345)), base_url="http://localhost") as client:
        cid = (await client.post("/api/courses/init-defaults")).json()["data"][0]["id"]
        yield client, db, dispatcher, cfg, cid
    await db.dispose()


async def upload(env, data=b"test audio", chunked=False):
    client, db, dispatcher, cfg, cid = env
    rec = (await client.post("/api/recordings", json={"course_id": cid, "duration_ms": 90000, "codec": "wav"})).json()["data"]
    rid = rec["id"]
    if chunked:
        await client.post(f"/api/recordings/{rid}/upload", data={"chunk_index": 0, "total_chunks": 1}, files={"file": ("part.wav", data)})
        async with db.session_scope() as s:
            assert (await s.scalars(select(AsrJob))).first() is None
        response = await client.post(f"/api/recordings/{rid}/complete")
    else:
        response = await client.post(f"/api/recordings/{rid}/upload-file", files={"file": ("audio.wav", data)})
    assert response.status_code == 200, response.text
    return rid, response.json()["data"]


@pytest.mark.parametrize("chunked", [False, True])
async def test_complete_only_enqueues_and_wakes(env, chunked):
    _, db, dispatcher, _, _ = env
    rid, rec = await upload(env, chunked=chunked)
    async with db.session_scope() as s:
        jobs = (await s.scalars(select(AsrJob))).all()
        assert len(jobs) == 1 and jobs[0].recording_id == rid
    assert dispatcher.wake.is_set()


async def test_duplicate_upload_same_bytes_one_job(env):
    client, db, *_ = env
    rid, _ = await upload(env)
    response = await client.post(f"/api/recordings/{rid}/upload-file", files={"file": ("audio.wav", b"test audio")})
    assert response.status_code == 200
    async with db.session_scope() as s:
        assert len((await s.scalars(select(AsrJob))).all()) == 1


async def test_missing_chunks_cannot_complete_or_enqueue(env):
    client, db, _, _, cid = env
    rid = (await client.post('/api/recordings', json={'course_id': cid, 'codec': 'wav'})).json()['data']['id']
    await client.post(f'/api/recordings/{rid}/upload', data={'chunk_index': 0, 'total_chunks': 2}, files={'file': ('part.wav', b'FIRST')})
    assert (await client.post(f'/api/recordings/{rid}/complete')).status_code != 200
    async with db.session_scope() as s:
        assert not (await s.scalars(select(AsrJob))).all()


async def test_disabled_no_backfill(env):
    client, db, dispatcher, cfg, _ = env
    cfg.enabled = False
    save_settings(cfg)
    await upload(env)
    cfg.enabled = True
    save_settings(cfg)
    await dispatcher.start()
    await asyncio.sleep(.02)
    await dispatcher.stop()
    async with db.session_scope() as s:
        assert not (await s.scalars(select(AsrJob))).all()


def result(chars=1600, aligned=True, end=90):
    return {"duration": 90, "segments": [{"s": 0, "e": end, "t": "课" * chars}], "aligned": aligned,
            "engine": "Qwen3-ASR-1.7B", "elapsed_sec": 1}


@pytest.mark.parametrize("chars,aligned,end,deleted", [(1600, True, 90, True), (1499, True, 90, False), (1600, False, 90, False)])
async def test_cleanup_gates_and_phone_receipt(env, monkeypatch, chars, aligned, end, deleted):
    client, db, dispatcher, *_ = env
    rid, rec = await upload(env)
    monkeypatch.setattr(asr_jobs, "infer", lambda *a: result(chars, aligned, end))
    async with db.session_scope() as s:
        job = (await s.scalars(select(AsrJob))).one()
        ident = job.id
    await dispatcher.execute(ident)
    async with db.session_scope() as s:
        job = await s.get(AsrJob, ident)
        assert job.status == ("completed" if aligned else "incomplete")
        assert job.result["source_deleted"] == deleted
        assert job.result["ledger_appended"]
        assert Path(job.result["output_path"]).is_file()
        assert Path(rec["file_path"]).exists() == (not deleted)
    receipt = (await client.get(f"/api/recordings/{rid}")).json()["data"]
    # Existing upload queue needs these to delete its phone copy after retry.
    assert receipt["upload_status"] == "uploaded" and receipt["file_path"] and receipt["size_bytes"] == len(b"test audio")


async def test_ledger_failure_never_deletes_and_retry_no_duplicate(env, monkeypatch):
    _, db, dispatcher, cfg, _ = env
    _, rec = await upload(env)
    monkeypatch.setattr(asr_jobs, "infer", lambda *a: result())
    real = asr_archive.ledger
    monkeypatch.setattr(asr_archive, "ledger", lambda *a: (_ for _ in ()).throw(OSError("ledger unavailable")))
    async with db.session_scope() as s:
        ident = (await s.scalars(select(AsrJob))).one().id
    await dispatcher.execute(ident)
    assert Path(rec["file_path"]).exists()
    async with db.session_scope() as s:
        assert (await s.get(AsrJob, ident)).status == "failed"
    monkeypatch.setattr(asr_archive, "ledger", real)
    await dispatcher.execute(ident)
    await dispatcher.execute(ident)
    assert len(list(Path(cfg.output_dir).glob("*.txt"))) == 1
    text = (Path(cfg.output_dir) / "00-转写完成清单.md").read_text("utf-8")
    assert text.count(ident + "-r0:ready") == 1 and text.count(ident + "-r0:cleanup") == 1


async def test_source_replaced_during_inference_retained(env, monkeypatch):
    _, db, dispatcher, *_ = env
    _, rec = await upload(env)
    def replace(*args):
        Path(rec["file_path"]).write_bytes(b"NEW AUDIO")
        return result()
    monkeypatch.setattr(asr_jobs, "infer", replace)
    async with db.session_scope() as s:
        ident = (await s.scalars(select(AsrJob))).one().id
    await dispatcher.execute(ident)
    assert Path(rec["file_path"]).read_bytes() == b"NEW AUDIO"
    async with db.session_scope() as s:
        assert (await s.get(AsrJob, ident)).status == "failed"


async def test_final_ledger_failure_reports_actual_deleted_state(env, monkeypatch):
    _, db, dispatcher, cfg, _ = env
    _, rec = await upload(env)
    monkeypatch.setattr(asr_jobs, "infer", lambda *a: result())
    real = asr_archive.ledger
    def partial(output, marker, text):
        if marker.endswith(':cleanup'):
            raise OSError('final ledger blocked')
        real(output, marker, text)
    monkeypatch.setattr(asr_archive, 'ledger', partial)
    async with db.session_scope() as s:
        ident = (await s.scalars(select(AsrJob))).one().id
    await dispatcher.execute(ident)
    async with db.session_scope() as s:
        job = await s.get(AsrJob, ident)
        assert job.status == 'completed' and job.result['source_deleted']
        assert 'final ledger blocked' in job.error and job.result['ledger_appended']
    assert not Path(rec['file_path']).exists()


async def test_existing_transcript_preserved(env, monkeypatch):
    _, db, dispatcher, cfg, _ = env
    _, rec = await upload(env)
    monkeypatch.setattr(asr_jobs, "infer", lambda *a: result())
    async with db.session_scope() as s:
        job = (await s.scalars(select(AsrJob))).one()
        from app.db.models import Course
        recording = await s.get(Recording, job.recording_id)
        course = await s.get(Course, recording.course_id)
        from datetime import datetime
        name = f"{datetime.fromtimestamp(job.source_mtime):%Y-%m-%d}_{Path(rec['file_path']).stem}_AI转写.txt"
        previous = Path(cfg.output_dir) / name
        previous.write_text("ORIGINAL", "utf-8")
        os.utime(previous, (job.source_mtime - 5, job.source_mtime - 5))
    await dispatcher.execute(job.id)
    assert previous.read_text("utf-8") == "ORIGINAL"
    assert len(list(Path(cfg.output_dir).glob("*.txt"))) == 2


async def test_failed_is_not_automatically_retried_forever(env, monkeypatch):
    _, db, dispatcher, *_ = env
    await upload(env)
    calls = []
    def fail(*args):
        calls.append(1)
        raise RuntimeError("ASR offline")
    monkeypatch.setattr(asr_jobs, "infer", fail)
    await dispatcher.start()
    for _ in range(50):
        await asyncio.sleep(.01)
        async with db.session_scope() as s:
            job = (await s.scalars(select(AsrJob))).one()
            if job.status == "failed":
                break
    await dispatcher.stop()
    assert len(calls) == 1
    assert job.error == "ASR offline"


async def test_running_recovered_and_pending_persisted(env, monkeypatch):
    _, db, dispatcher, *_ = env
    await upload(env)
    async with db.session_scope() as s:
        job = (await s.scalars(select(AsrJob))).one()
        job.status = "running"
    calls = []
    async def execute(ident):
        calls.append(ident)
        dispatcher.stop_event.set()
    monkeypatch.setattr(dispatcher, "execute", execute)
    await dispatcher.start()
    await dispatcher.task
    assert calls == [job.id]


async def test_secret_masked_preserved_and_address_change_requires_decision(env):
    client, _, _, cfg, _ = env
    cfg.api_key = "PRIVATE_TEST_ONLY"
    cfg.mode = "qwen_service"
    save_settings(cfg)
    public = (await client.get("/api/settings/asr")).json()["data"]
    assert "api_key" not in public and public["api_key_set"]
    payload = cfg.model_dump()
    payload["api_key"] = ""
    assert (await client.put("/api/settings/asr", json=payload)).status_code == 200
    assert load_settings().api_key == cfg.api_key
    payload["base_url"] = "http://localhost:9999/v1"
    assert (await client.put("/api/settings/asr", json=payload)).status_code != 200
    payload["clear_api_key"] = True
    assert (await client.put("/api/settings/asr", json=payload)).status_code == 200
    assert not load_settings().api_key


async def test_asr_settings_local_only(env):
    client, *_ = env
    from starlette.requests import Request
    from app.api.asr import settings
    from app.config import get_app_config
    from app.errors import ApiError
    request = Request({"type": "http", "client": ("192.168.137.178", 123), "headers": []})
    with pytest.raises(ApiError):
        await settings(request, get_app_config())


async def test_newer_complete_output_skips_qwen(env, monkeypatch):
    _, db, dispatcher, cfg, _ = env
    _, rec = await upload(env)
    from datetime import datetime
    async with db.session_scope() as s:
        job = (await s.scalars(select(AsrJob))).one()
    target = Path(cfg.output_dir) / f"{datetime.fromtimestamp(job.source_mtime):%Y-%m-%d}_{Path(rec['file_path']).stem}_AI转写.txt"
    target.write_text("已完整转写", "utf-8")
    os.utime(target, (job.source_mtime + 5, job.source_mtime + 5))
    monkeypatch.setattr(asr_jobs, "infer", lambda *a: (_ for _ in ()).throw(AssertionError("must skip")))
    await dispatcher.execute(job.id)
    async with db.session_scope() as s:
        final = await s.get(AsrJob, job.id)
        assert final.status == "completed" and final.result["skipped"]
    assert Path(rec["file_path"]).exists() and target.read_text("utf-8") == "已完整转写"


async def test_incomplete_retry_keeps_shards_and_old_output(env, monkeypatch):
    client, db, dispatcher, cfg, _ = env
    await upload(env)
    monkeypatch.setattr(asr_jobs, "infer", lambda *a: result(aligned=False))
    async with db.session_scope() as s:
        job = (await s.scalars(select(AsrJob))).one()
    await dispatcher.execute(job.id)
    work = dispatcher.work_root / job.id
    checkpoint = work / "c000.json"
    checkpoint.write_text("CHECKPOINT", "utf-8")
    originals = {p.name: p.read_bytes() for p in Path(cfg.output_dir).glob("*.txt")}
    assert (await client.post(f"/api/asr/jobs/{job.id}/retry")).status_code == 200
    assert checkpoint.read_text("utf-8") == "CHECKPOINT"
    monkeypatch.setattr(asr_jobs, "infer", lambda *a: result())
    await dispatcher.execute(job.id)
    assert all((Path(cfg.output_dir) / name).read_bytes() == data for name, data in originals.items())
    assert len(list(Path(cfg.output_dir).glob("*.txt"))) == 2


async def job_for(db, rid):
    async with db.session_scope() as session:
        return (await session.scalars(select(AsrJob).where(AsrJob.recording_id == rid))).one()


async def test_cancel_queued_is_durable_idempotent_and_explicitly_retryable(env, monkeypatch):
    client, db, dispatcher, *_ = env
    rid, rec = await upload(env)
    job = await job_for(db, rid)
    response = await client.post(f'/api/asr/jobs/{job.id}/cancel')
    assert response.status_code == 200
    assert response.json()['data']['status'] == 'cancelled'
    assert (await client.post(f'/api/asr/jobs/{job.id}/cancel')).json()['data']['status'] == 'cancelled'
    monkeypatch.setattr(asr_jobs, 'infer', lambda *a: (_ for _ in ()).throw(AssertionError('cancelled must not start')))
    await dispatcher.execute(job.id)
    assert (await job_for(db, rid)).status == 'cancelled'
    assert Path(rec['file_path']).is_file()
    response = await client.post(f'/api/asr/jobs/{job.id}/retry')
    assert response.status_code == 200 and response.json()['data']['status'] == 'queued'


async def test_cancel_running_stops_owned_process_before_terminal_state(env, monkeypatch):
    from app.services.asr_engine import run_process
    import subprocess
    client, db, dispatcher, cfg, _ = env
    rid, rec = await upload(env)
    job = await job_for(db, rid)
    pid_file = dispatcher.work_root / 'sleep.pid'
    def sleep_process(source, work, settings, stop):
        command = 'import os,time;from pathlib import Path;Path(' + repr(str(pid_file)) + ').write_text(str(os.getpid()));time.sleep(60)'
        run_process([sys.executable, '-c', command], work / 'sleep.log', stop)
        return result()
    monkeypatch.setattr(asr_jobs, 'infer', sleep_process)
    execution = asyncio.create_task(dispatcher.execute(job.id))
    for _ in range(300):
        if pid_file.exists():
            break
        await asyncio.sleep(.01)
    assert pid_file.exists()
    pid = int(pid_file.read_text())
    if os.name == 'nt':
        import ctypes
        from ctypes import wintypes
        ctypes.windll.kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        ctypes.windll.kernel32.OpenProcess.restype = wintypes.HANDLE
        ctypes.windll.kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        ctypes.windll.kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = ctypes.windll.kernel32.OpenProcess(0x100000, False, pid)
        assert handle
    response = await client.post(f'/api/asr/jobs/{job.id}/cancel')
    assert response.status_code == 200 and response.json()['data']['status'] == 'cancelling'
    assert (await client.delete(f'/api/asr/jobs/{job.id}')).status_code == 409
    await asyncio.wait_for(execution, 8)
    assert (await job_for(db, rid)).status == 'cancelled'
    if os.name == 'nt':
        assert ctypes.windll.kernel32.WaitForSingleObject(handle, 0) == 0
        ctypes.windll.kernel32.CloseHandle(handle)
    else:
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)
    assert Path(rec['file_path']).is_file()
    assert not list(Path(cfg.output_dir).glob('*.txt'))


async def test_cancel_after_infer_success_cannot_publish_or_delete(env, monkeypatch):
    client, db, dispatcher, cfg, _ = env
    rid, rec = await upload(env)
    job = await job_for(db, rid)
    entered, release = threading.Event(), threading.Event()
    def infer(*a):
        entered.set()
        assert release.wait(3)
        return result()
    monkeypatch.setattr(asr_jobs, 'infer', infer)
    execution = asyncio.create_task(dispatcher.execute(job.id))
    while not entered.is_set():
        await asyncio.sleep(.01)
    assert (await client.post(f'/api/asr/jobs/{job.id}/cancel')).json()['data']['status'] == 'cancelling'
    release.set()
    await execution
    assert (await job_for(db, rid)).status == 'cancelled'
    assert Path(rec['file_path']).is_file() and not list(Path(cfg.output_dir).iterdir())


async def test_cancel_saving_refused_and_committed_result_stays_consistent(env, monkeypatch):
    client, db, dispatcher, cfg, _ = env
    rid, rec = await upload(env)
    job = await job_for(db, rid)
    entered, release = threading.Event(), threading.Event()
    original = asr_jobs.publish
    def publish(*args):
        entered.set()
        assert release.wait(3)
        return original(*args)
    monkeypatch.setattr(asr_jobs, 'infer', lambda *a: result())
    monkeypatch.setattr(asr_jobs, 'publish', publish)
    execution = asyncio.create_task(dispatcher.execute(job.id))
    while not entered.is_set():
        await asyncio.sleep(.01)
    response = await client.post(f'/api/asr/jobs/{job.id}/cancel')
    assert response.status_code == 409 and '保存' in response.json()['message']
    release.set()
    await execution
    final = await job_for(db, rid)
    assert final.status == 'completed' and final.result['source_deleted']
    assert not Path(rec['file_path']).exists()


async def test_restart_cancelling_becomes_cancelled_not_queued(env):
    _, db, dispatcher, cfg, _ = env
    cfg.enabled = False
    save_settings(cfg)
    cfg.enabled = True
    save_settings(cfg)
    rid, _ = await upload(env)
    async with db.session_scope() as session:
        job = (await session.scalars(select(AsrJob))).one()
        job.status = 'cancelling'
    await dispatcher.start()
    await dispatcher.stop()
    assert (await job_for(db, rid)).status == 'cancelled'


async def test_task_delete_keeps_audio_outputs_and_tombstone_blocks_duplicate_upload(env):
    client, db, _, cfg, _ = env
    rid, rec = await upload(env)
    job = await job_for(db, rid)
    assert (await client.delete(f'/api/asr/jobs/{job.id}')).status_code == 409
    await client.post(f'/api/asr/jobs/{job.id}/cancel')
    transcript = Path(cfg.output_dir) / 'existing.txt'
    transcript.write_text('ORIGINAL TRANSCRIPT', 'utf-8')
    ledger = Path(cfg.output_dir) / '00-转写完成清单.md'
    ledger.write_text('ORIGINAL LEDGER', 'utf-8')
    assert (await client.delete(f'/api/asr/jobs/{job.id}')).status_code == 200
    assert (await client.delete(f'/api/asr/jobs/{job.id}')).status_code == 200
    assert not (await client.get('/api/asr/jobs?all=true')).json()['data']
    assert (await client.post(f'/api/asr/jobs/{job.id}/retry')).status_code == 404
    assert Path(rec['file_path']).read_bytes() == b'test audio'
    assert transcript.read_text('utf-8') == 'ORIGINAL TRANSCRIPT'
    assert ledger.read_text('utf-8') == 'ORIGINAL LEDGER'
    assert (await client.post(f'/api/recordings/{rid}/upload-file', files={'file': ('audio.wav', b'test audio')})).status_code == 200
    assert (await job_for(db, rid)).status == 'deleted'


@pytest.mark.parametrize('status', ['failed', 'incomplete', 'cancelled'])
async def test_delete_failed_audio_is_idempotent_but_invalidates_cleanup_receipt(env, status):
    client, db, dispatcher, cfg, _ = env
    rid, rec = await upload(env)
    async with db.session_scope() as session:
        job = (await session.scalars(select(AsrJob))).one()
        job.status = status
    transcript = Path(cfg.output_dir) / 'old.txt'
    transcript.write_bytes(b'KEEP')
    response = await client.delete(f'/api/asr/jobs/{job.id}/recording')
    assert response.status_code == 200, response.text
    value = response.json()['data']
    assert value['result']['source_deleted'] and not value['can_retry'] and not value['can_delete_recording']
    assert not Path(rec['file_path']).exists() and transcript.read_bytes() == b'KEEP'
    again = await client.delete(f'/api/asr/jobs/{job.id}/recording')
    assert again.status_code == 200
    receipt = (await client.get(f'/api/recordings/{rid}')).json()['data']
    assert receipt['file_path'] == rec['file_path'] and receipt['upload_status'] == 'pending' and receipt['deleted_at']
    assert not receipt['cleanup_receipt']['verified']
    assert receipt['size_bytes'] == len(b'test audio')
    assert (await client.post(f'/api/asr/jobs/{job.id}/retry')).status_code == 409


@pytest.mark.parametrize('change', ['bytes', 'path', 'outside', 'directory'])
async def test_delete_failed_audio_refuses_replacements_and_unsafe_paths(env, tmp_path, change):
    client, db, _, _, _ = env
    rid, rec = await upload(env)
    original = Path(rec['file_path'])
    async with db.session_scope() as session:
        job = (await session.scalars(select(AsrJob))).one()
        job.status = 'failed'
        recording = await session.get(Recording, rid)
        if change == 'bytes':
            original.write_bytes(b'NEW AUDIO')
        elif change == 'path':
            recording.file_path = str(tmp_path / 'different.wav')
        elif change == 'outside':
            outside = tmp_path / 'outside.wav'
            outside.write_bytes(b'test audio')
            job.source_path = recording.file_path = str(outside)
            info = outside.stat()
            job.source_size, job.source_mtime = info.st_size, info.st_mtime
        else:
            original.unlink()
            original.mkdir()
    response = await client.delete(f'/api/asr/jobs/{job.id}/recording')
    assert response.status_code == 409, response.text
    assert original.exists()
    if change == 'bytes':
        assert original.read_bytes() == b'NEW AUDIO'
    if change == 'outside':
        assert outside.read_bytes() == b'test audio'


async def test_delete_audio_refuses_other_active_job_for_same_recording(env):
    client, db, *_ = env
    rid, rec = await upload(env)
    async with db.session_scope() as session:
        job = (await session.scalars(select(AsrJob))).one()
        job.status = 'failed'
        other = AsrJob(id=job.id+'other', recording_id=rid, source_sha256='0'*64, source_path=job.source_path,
                       source_size=job.source_size, source_mtime=job.source_mtime, status='queued')
        session.add(other)
    assert (await client.delete(f'/api/asr/jobs/{job.id}/recording')).status_code == 409
    assert Path(rec['file_path']).exists()


async def test_delete_audio_refuses_active_upload_even_for_uploaded_receipt(env):
    from app.services.upload_progress import active_uploads
    client, db, *_ = env
    rid, rec = await upload(env)
    async with db.session_scope() as session:
        job = (await session.scalars(select(AsrJob))).one()
        job.status = 'failed'
    active_uploads[rid] = {'phase': 'saving'}
    try:
        assert (await client.delete(f'/api/asr/jobs/{job.id}/recording')).status_code == 409
        assert Path(rec['file_path']).exists()
    finally:
        active_uploads.pop(rid, None)


async def test_upload_and_delete_share_commit_gate(env, monkeypatch):
    client, db, dispatcher, *_ = env
    rid, rec = await upload(env)
    async with db.session_scope() as session:
        job = (await session.scalars(select(AsrJob))).one()
        job.status = 'failed'
    await dispatcher.mutations.acquire()
    uploading = asyncio.create_task(client.post(f'/api/recordings/{rid}/upload-file', files={'file': ('audio.wav', b'NEW AUDIO')}))
    await asyncio.sleep(.05)
    assert not uploading.done() and Path(rec['file_path']).read_bytes() == b'test audio'
    dispatcher.mutations.release()
    assert (await uploading).status_code == 200
    assert (await client.delete(f'/api/asr/jobs/{job.id}/recording')).status_code == 409
    assert Path(rec['file_path']).read_bytes() == b'NEW AUDIO'


async def test_all_jobs_removes_old_limit_and_hides_deleted(env):
    client, db, *_ = env
    rid, _ = await upload(env)
    original = await job_for(db, rid)
    async with db.session_scope() as session:
        for index in range(103):
            session.add(AsrJob(id=f'history{index:03}', recording_id=rid, source_sha256=f'{index:064x}',
                              source_path=original.source_path,source_size=original.source_size,
                              source_mtime=original.source_mtime,status='deleted' if index==0 else 'failed'))
    recent=(await client.get('/api/asr/jobs')).json()['data']
    all_jobs=(await client.get('/api/asr/jobs?all=true')).json()['data']
    assert len(recent)==100 and len(all_jobs)==103
    assert all(x['status']!='deleted' for x in all_jobs)
    assert all(set(('can_cancel','can_delete','can_delete_recording','can_retry')) <= x.keys() for x in all_jobs)


async def test_failed_process_stop_keeps_cancelling_active_and_engine_owned(env, monkeypatch):
    from app.services import asr_engine
    from app.services.asr_process import ProcessStopFailed
    client, db, dispatcher, cfg, _ = env
    rid, rec = await upload(env)
    job = await job_for(db, rid)
    pid_file = dispatcher.work_root / 'held-sleep.pid'
    failed, allow_stop = threading.Event(), threading.Event()
    actual_stop = asr_engine.stop_owned_process
    def held_stop(process, tree):
        if not allow_stop.is_set():
            failed.set()
            raise ProcessStopFailed('模拟终止失败：尚未确认退出')
        return actual_stop(process, tree)
    monkeypatch.setattr(asr_engine, 'stop_owned_process', held_stop)
    def sleep_process(source, work, settings, stop):
        command = 'import os,time;from pathlib import Path;Path(' + repr(str(pid_file)) + ').write_text(str(os.getpid()));time.sleep(60)'
        asr_engine.run_process([sys.executable, '-c', command], work / 'held-sleep.log', stop)
        return result()
    monkeypatch.setattr(asr_jobs, 'infer', sleep_process)
    execution = asyncio.create_task(dispatcher.execute(job.id))
    try:
        for _ in range(300):
            if pid_file.exists(): break
            await asyncio.sleep(.01)
        assert pid_file.exists()
        response = await client.post(f'/api/asr/jobs/{job.id}/cancel')
        assert response.status_code == 200 and response.json()['data']['status'] == 'cancelling'
        for _ in range(100):
            if failed.is_set(): break
            await asyncio.sleep(.01)
        assert failed.is_set()
        assert (await job_for(db, rid)).status == 'cancelling'
        assert not execution.done()
        control = dispatcher.active[job.id]
        assert control.processes and control.stop_error and control.cancelled.is_set()
        assert (await client.delete(f'/api/asr/jobs/{job.id}')).status_code == 409
        assert (await client.post(f'/api/asr/jobs/{job.id}/retry')).status_code == 409
        assert (await client.delete(f'/api/asr/jobs/{job.id}/recording')).status_code == 409
        assert Path(rec['file_path']).exists() and not list(Path(cfg.output_dir).iterdir())
    finally:
        allow_stop.set()
        await asyncio.wait_for(execution, 8)
    assert (await job_for(db, rid)).status == 'cancelled'
    assert job.id not in dispatcher.active and not control.processes
