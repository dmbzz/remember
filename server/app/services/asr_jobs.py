"""A durable, serial ASR queue, woken only by completed uploads or explicit retries."""
from __future__ import annotations

import asyncio
import json
import logging
import threading
import time
from datetime import datetime
from pathlib import Path

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError

from app.config import get_app_config
from app.db.models import AsrJob, Recording
from app.db.session import Database
from app.services.asr_archive import atomic_json, publish, covered_transcript
from app.services.asr_engine import infer, service_infer, sha256
from app.services.asr_settings import load_settings, validate_settings
from app.services.asr_lock import engine_lock
from app.services.asr_progress import update_progress, read_progress
from app.services.desktop_notifications import notify_asr

log = logging.getLogger(__name__)


def existing_output(source, job, cfg, cached, work, generation, duration):
    if cached.exists() or (work / f"archive-{generation}.json").exists():
        return None
    covered = covered_transcript(source, job.source_mtime, Path(cfg.output_dir))
    if not covered:
        return None
    return {"output_path": str(covered), "source_deleted": False,
            "source_note": "保留：已有较新的完整转写，跳过重复识别和清理", "skipped": True,
            "complete": True, "ledger_appended": False, "segments": 0, "chars": 0,
            "duration_sec": duration, "elapsed_sec": 0}


def local_pipeline(source, work, job, generation, cached, title, cfg, stop, duration):
    # Keep ownership through archive/cleanup, so the old daily task cannot scan
    # and consume this same source between inference and publication.
    update_progress(work, "waiting_engine")
    with engine_lock(stop):
        covered = existing_output(source, job, cfg, cached, work, generation, duration)
        if covered:
            return covered
        if cached.exists():
            result = json.loads(cached.read_text("utf-8"))
        else:
            if not source.is_file() or sha256(source) != job.source_sha256:
                raise ValueError("待转写源音频不存在或已被替换")
            result = infer(source, work, cfg, stop)
            atomic_json(cached, result)
        update_progress(work, "saving")
        return publish(source, work, generation, job.source_sha256, job.source_mtime, title, result, cfg)


async def enqueue_uploaded(session, rec) -> AsrJob | None:
    cfg = load_settings()
    if not cfg.enabled:
        return None
    source = Path(rec.file_path or "")
    if rec.upload_status != "uploaded" or not source.is_file():
        return None
    digest = await asyncio.to_thread(sha256, source)
    job_id = f"{rec.id}_{digest[:20]}"
    existing = await session.get(AsrJob, job_id)
    if existing:
        return existing
    stat = source.stat()
    job = AsrJob(id=job_id, recording_id=rec.id, source_sha256=digest,
                 source_path=str(source), source_mtime=stat.st_mtime, source_size=stat.st_size)
    try:
        async with session.begin_nested():
            session.add(job)
            await session.flush()
    except IntegrityError:
        return await session.get(AsrJob, job_id)
    return job


class AsrDispatcher:
    def __init__(self, database: Database, work_root: Path | None = None):
        self.database = database
        self.work_root = work_root or Path(get_app_config().storage_root) / "asr-jobs"
        self.wake = asyncio.Event()
        self.stop_event = threading.Event()
        self.task = None

    async def start(self):
        # A server exit never loses a persisted job. No scan/backfill of old audio.
        async with self.database.session_scope() as s:
            await s.execute(update(AsrJob).where(AsrJob.status == "running").values(status="queued"))
        self.task = asyncio.create_task(self.run(), name="qwen-asr-dispatcher")

    async def stop(self):
        self.stop_event.set()
        self.wake.set()
        if self.task:
            await self.task

    async def run(self):
        while not self.stop_event.is_set():
            try:
                cfg = load_settings()
                if cfg.enabled:
                    async with self.database.session_scope() as s:
                        job = (await s.scalars(select(AsrJob).where(AsrJob.status == "queued").order_by(AsrJob.created_at).limit(1))).first()
                        ident = job.id if job else None
                    if ident:
                        await self.execute(ident)
                        continue
            except Exception:
                log.exception("ASR queue unavailable; durable jobs are retained")
            self.wake.clear()
            try:
                await asyncio.wait_for(self.wake.wait(), 5)
            except TimeoutError:
                pass

    async def execute(self, ident):
        try:
            cfg = load_settings()
            validate_settings(cfg)
            async with self.database.session_scope() as s:
                job = await s.get(AsrJob, ident)
                job.status, job.started_at, job.error = "running", datetime.now(), ""
                rec = await s.get(Recording, job.recording_id)
                from app.db.models import Course
                course = await s.get(Course, rec.course_id)
                title = course.name if course else Path(job.source_path).stem
                rec.transcription_status = "running"
            source, work = Path(job.source_path), self.work_root / ident
            work.mkdir(parents=True, exist_ok=True)
            update_progress(work, "preparing", generation=job.run_generation)
            await asyncio.to_thread(notify_asr, "started", source.name)
            generation = f"{ident}-r{job.run_generation}"
            cached = work / f"inference-{generation}.json"
            if cfg.mode == "local_qwen":
                result = await asyncio.to_thread(local_pipeline, source, work, job, generation, cached, title, cfg, self.stop_event, rec.duration_ms / 1000)
            else:
                start = time.monotonic()
                covered = await asyncio.to_thread(existing_output, source, job, cfg, cached, work, generation, rec.duration_ms / 1000)
                if covered:
                    result = covered
                else:
                    if cached.exists():
                        result = json.loads(cached.read_text("utf-8"))
                    else:
                        if not source.is_file() or await asyncio.to_thread(sha256, source) != job.source_sha256:
                            raise ValueError("待转写源音频不存在或已被替换")
                        update_progress(work, "service")
                        result = await service_infer(source, cfg, self.stop_event)
                        expected = rec.duration_ms / 1000
                        if expected <= 0 or abs(result["duration"] - expected) > max(2, expected * .01):
                            result["coverage_complete"] = False
                        result["elapsed_sec"] = round(time.monotonic() - start, 2)
                        atomic_json(cached, result)
                    update_progress(work, "saving")
                    result = await asyncio.to_thread(publish, source, work, generation, job.source_sha256, job.source_mtime, title, result, cfg)
            async with self.database.session_scope() as s:
                current = await s.get(AsrJob, ident)
                current.result, current.status, current.finished_at = result, "completed" if result["complete"] else "incomplete", datetime.now()
                current.error = result.get("ledger_warning", "")
                rec = await s.get(Recording, job.recording_id)
                # Keep file_path/size/uploaded as the durable reception receipt for
                # older phone clients, even after authorized PC source deletion.
                if rec.file_path == job.source_path:
                    rec.transcription_status = "success" if result["complete"] else "failed"
                    if result["source_deleted"]:
                        rec.deleted_at = datetime.now()
            if result["complete"]:
                # Remove only generated WAVs under this job's verified work root.
                # Keep small receipts/shards so retries don't repeat inference.
                if not work.resolve().is_relative_to(self.work_root.resolve()):
                    raise ValueError("转写临时目录越界")
                for generated in work.glob("*.wav"):
                    generated.unlink(missing_ok=True)
            await asyncio.to_thread(notify_asr, "completed" if result["complete"] else "incomplete", source.name)
        except Exception as exc:
            async with self.database.session_scope() as s:
                job = await s.get(AsrJob, ident)
                job.status = "queued" if self.stop_event.is_set() else "failed"
                job.error = str(exc)
                rec = await s.get(Recording, job.recording_id)
                if rec:
                    rec.transcription_status = "pending" if self.stop_event.is_set() else "failed"
            if not self.stop_event.is_set():
                await asyncio.to_thread(notify_asr, "failed", Path(job.source_path).name)


def job_dict(job: AsrJob) -> dict:
    return {"id": job.id, "recording_id": job.recording_id, "status": job.status,
            "error": job.error, "result": job.result, "source_name": Path(job.source_path).name,
            "progress": read_progress(job, Path(get_app_config().storage_root) / "asr-jobs"),
            "created_at": job.created_at.isoformat(),
            "started_at": job.started_at.isoformat() if job.started_at else None,
            "finished_at": job.finished_at.isoformat() if job.finished_at else None}
