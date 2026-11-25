"""Verify recoverable content, not a historical database upload flag."""
from __future__ import annotations

import asyncio
import hashlib
from pathlib import Path

from sqlalchemy import select

from app.db.models import AsrJob


def fingerprint(path: Path) -> tuple[int, str] | None:
    """Reject a file changed/replaced while being read; no user file is written."""
    try:
        with path.open('rb') as stream:
            import os
            before = os.fstat(stream.fileno())
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            after = os.fstat(stream.fileno())
        current = path.stat()
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            return None
        return after.st_size, digest
    except (OSError, ValueError):
        return None


async def verify_receipt(session, rec, *, expected_hash: str | None = None,
                         expected_size: int | None = None) -> dict:
    size = rec.size_bytes if expected_size is None else expected_size
    receipt = {'recording_id': rec.id, 'verified': False, 'basis': None,
               'size_bytes': size, 'sha256': expected_hash}
    if rec.upload_status != 'uploaded' or size <= 0:
        return receipt
    source = await asyncio.to_thread(fingerprint, Path(rec.file_path)) if rec.file_path else None
    if source and source[0] == size and (expected_hash is None or source[1] == expected_hash):
        return {**receipt, 'verified': True, 'basis': 'audio', 'sha256': source[1]}
    # Successful ASR may intentionally delete source audio. A durable, still valid
    # full transcript is sufficient; cancelled/manual deletion alone is not.
    jobs = (await session.scalars(select(AsrJob).where(
        AsrJob.recording_id == rec.id, AsrJob.source_size == size))).all()
    for job in jobs:
        if expected_hash is not None and job.source_sha256 != expected_hash:
            continue
        result = job.result or {}
        if not result.get('complete') or not result.get('ledger_appended'):
            continue
        output, digest = result.get('output_path'), result.get('output_sha256')
        if not output or not digest:
            continue
        archived = await asyncio.to_thread(fingerprint, Path(output))
        if archived and archived[0] > 0 and archived[1] == digest:
            return {**receipt, 'verified': True, 'basis': 'transcript',
                    'sha256': job.source_sha256}
    return receipt
