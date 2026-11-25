from pathlib import Path

from sqlalchemy import select

from test_asr_upload import env, upload, result
from app.db.models import AsrJob
from app.services import asr_jobs
from app.services.asr_settings import save_settings


async def test_service_retry_preserves_cached_engine_incomplete_evidence(env, monkeypatch):
    client, db, dispatcher, cfg, _ = env
    _, rec = await upload(env)
    cached_result = {**result(), "coverage_complete": False}
    monkeypatch.setattr(asr_jobs, "infer", lambda *args: cached_result)
    real_publish = asr_jobs.publish

    def unavailable_archive(*args):
        raise OSError("simulated archive temporarily unavailable")

    monkeypatch.setattr(asr_jobs, "publish", unavailable_archive)
    async with db.session_scope() as session:
        ident = (await session.scalars(select(AsrJob))).one().id
    await dispatcher.execute(ident)
    async with db.session_scope() as session:
        failed = await session.get(AsrJob, ident)
        assert failed.status == "failed" and failed.run_generation == 0
    source = Path(rec["file_path"])
    assert source.exists()

    # Failed-job retries retain the generation/cache. A mode change must not
    # erase the local engine's coverage=False, even when duration is accurate.
    cfg.mode = "qwen_service"
    save_settings(cfg)
    monkeypatch.setattr(asr_jobs, "publish", real_publish)

    async def unexpected_inference(*args):
        raise AssertionError("retry should reuse the durable inference cache")

    monkeypatch.setattr(asr_jobs, "service_infer", unexpected_inference)
    assert (await client.post(f"/api/asr/jobs/{ident}/retry")).status_code == 200
    await dispatcher.execute(ident)
    async with db.session_scope() as session:
        retried = await session.get(AsrJob, ident)
        assert retried.status == "incomplete", retried.error
        assert not retried.result["complete"]
        assert not retried.result["source_deleted"]
    assert source.read_bytes() == b"test audio"
