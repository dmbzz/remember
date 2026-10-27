from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app.services.recording_filename import native_recording_start, recording_destination
from app.services.recording_service import RecordingService


def test_filename_is_safe_and_duplicate_is_preserved(tmp_path):
    start = datetime(2026, 10, 12, 19, 30)
    first = recording_destination(tmp_path, '工程/力学:*', start, 'm4a')
    assert first.name == '工程_力学___2026-10-12_19-30-00.m4a'
    first.write_bytes(b'original')
    second = recording_destination(tmp_path, '工程/力学:*', start, 'm4a')
    assert second.name.endswith(' (2).m4a')
    assert first.read_bytes() == b'original'
    assert recording_destination(tmp_path, '工程/力学:*', start, 'm4a', str(first)) == first
    with pytest.raises(ValueError):
        recording_destination(tmp_path, '工程力学', start, '../exe')


@pytest.mark.asyncio
async def test_direct_upload_uses_native_start_and_retries_same_file(tmp_path):
    session = SimpleNamespace(flush=AsyncMock())
    service = RecordingService(session, SimpleNamespace(resolved_storage_root=tmp_path))
    rec = SimpleNamespace(id='rec_test', course=SimpleNamespace(name='工程力学'),
                          started_at=datetime(2026, 10, 12, 21, 43), file_path=None)
    service.get_recording = AsyncMock(return_value=rec)
    filename = 'rec_rec_auto_course_8747fb40236b_1791804600000_20261012_193000.m4a'
    await service.save_direct_file(rec.id, b'audio', filename)
    saved = Path(rec.file_path)
    assert saved.name == '工程力学_2026-10-12_19-30-00.m4a'
    assert rec.started_at.hour == 19
    await service.save_direct_file(rec.id, b'audio', filename)
    assert Path(rec.file_path) == saved
    assert list(saved.parent.glob('*.m4a')) == [saved]
    other = SimpleNamespace(id='rec_other', course=rec.course,
                            started_at=rec.started_at, file_path=None)
    service.get_recording = AsyncMock(return_value=other)
    await service.save_direct_file(other.id, b'other audio', filename)
    assert Path(other.file_path).name == '工程力学_2026-10-12_19-30-00 (2).m4a'
    assert saved.read_bytes() == b'audio'


@pytest.mark.asyncio
async def test_chunks_use_same_naming_rule(tmp_path):
    service = RecordingService(SimpleNamespace(flush=AsyncMock()),
                               SimpleNamespace(resolved_storage_root=tmp_path))
    rec = SimpleNamespace(id='rec_chunks', course=SimpleNamespace(name='线性代数'),
                          started_at=datetime(2026, 10, 12, 10, 5), file_path=None, codec='aac')
    service.get_recording = AsyncMock(return_value=rec)
    await service.save_chunk(rec.id, 0, b'one')
    await service.save_chunk(rec.id, 1, b'two')
    await service.complete_upload(rec.id)
    assert Path(rec.file_path).name == '线性代数_2026-10-12_10-05-00.aac'
    assert Path(rec.file_path).read_bytes() == b'onetwo'


def test_unrecognized_filename_does_not_invent_start():
    assert native_recording_start('audio.m4a') is None
    assert native_recording_start('rec_test_1791804600000_20261312_193000.m4a') is None
