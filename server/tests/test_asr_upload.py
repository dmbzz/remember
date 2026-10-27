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
