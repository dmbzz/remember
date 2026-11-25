from pathlib import Path
import hashlib
import io
import struct
import wave

import pytest
from sqlalchemy import select

from test_asr_upload import env, upload, result
from app.db.models import AsrJob, Course, Recording, ScheduleEntry
from app.services import asr_jobs
from app.services.asr_settings import save_settings
from app.services.audio_duration import audio_duration


async def receipt(client, rid, data=b'test audio'):
    response = await client.get(f'/api/recordings/{rid}/receipt', params={
        'sha256': hashlib.sha256(data).hexdigest(), 'size_bytes': len(data)})
    assert response.status_code == 200, response.text
    return response.json()['data']


async def test_cleanup_requires_real_audio_or_verified_archive(env, monkeypatch):
    client, db, dispatcher, cfg, cid = env
    rid, rec = await upload(env)
    assert (await receipt(client, rid))['basis'] == 'audio'
    assert (await receipt(client, rid, b'other data'))['verified'] is False
    source = Path(rec['file_path'])
    source.unlink()
    assert (await receipt(client, rid))['verified'] is False
    assert (await client.get(f'/api/recordings/{rid}')).json()['data']['upload_status'] == 'pending'
    # Reupload recovers the original ID; full ASR archive may replace audio.
    await client.post(f'/api/recordings/{rid}/upload-file', files={'file':('audio.wav',b'test audio')})
    monkeypatch.setattr(asr_jobs,'infer',lambda *a:result())
    async with db.session_scope() as s:
        job_id=(await s.scalars(select(AsrJob))).one().id
    await dispatcher.execute(job_id)
    assert not source.exists()
    verified=await receipt(client,rid)
    assert verified['verified'] and verified['basis']=='transcript'
    identity=(await client.get('/api/pairing/check')).json()['data']['server_id']
    assert verified['server_id']==identity
    assert (await client.get(f'/api/recordings/{rid}')).json()['data']['upload_status']=='uploaded'
    async with db.session_scope() as s:
        output=Path((await s.get(AsrJob,job_id)).result['output_path'])
    output.write_text('modified outside app',encoding='utf-8')
    assert not (await receipt(client,rid))['verified']
    assert (await client.get(f'/api/recordings/{rid}')).json()['data']['upload_status']=='pending'


async def test_same_size_changed_audio_cannot_authorize_phone_cleanup(env):
    client,*_=env
    rid,rec=await upload(env)
    Path(rec['file_path']).write_bytes(b'fake audio')
    assert not (await receipt(client,rid))['verified']


@pytest.mark.parametrize('total,expected_size,parts,allowed',[
    (None,100,[b'1234567890'],False), (None,0,[b'123'],False),
    (2,6,[b'123'],False), (2,7,[b'123',b'456'],False),
    (2,6,[b'123',b'456'],True), (None,6,[b'123',b'456'],True),
    (2,0,[b'123',b'456'],True),
])
async def test_chunk_completion_checks_declared_bounds(env,total,expected_size,parts,allowed):
    client,db,dispatcher,cfg,cid=env
    rec=(await client.post('/api/recordings',json={'course_id':cid,'codec':'wav','size_bytes':expected_size})).json()['data']
    for index,part in enumerate(parts):
        form={'chunk_index':index}
        if total is not None: form['total_chunks']=total
        assert (await client.post(f"/api/recordings/{rec['id']}/upload",data=form,files={'file':('part.wav',part)})).status_code==200
    response=await client.post(f"/api/recordings/{rec['id']}/complete")
    assert (response.status_code==200)==allowed,response.text
    async with db.session_scope() as s:
        stored=await s.get(Recording,rec['id'])
        assert (stored.upload_status=='uploaded')==allowed
        assert bool((await s.scalars(select(AsrJob))).all())==allowed


def wav_bytes(seconds):
    data=io.BytesIO()
    with wave.open(data,'wb') as stream:
        stream.setnchannels(1);stream.setsampwidth(2);stream.setframerate(100)
        stream.writeframes(b'\0\0'*(seconds*100))
    return data.getvalue()


@pytest.mark.parametrize('service_duration,complete',[(90,True),(20,False)])
async def test_legacy_phone_zero_duration_uses_source_container(env,monkeypatch,service_duration,complete):
    client,db,dispatcher,cfg,cid=env
    cfg.mode='qwen_service';save_settings(cfg)
    async def infer(*args):
        response=result(end=service_duration);response['duration']=service_duration
        return response
    monkeypatch.setattr(asr_jobs,'service_infer',infer)
    data=wav_bytes(90)
    rec=(await client.post('/api/recordings',json={'course_id':cid,'codec':'wav','size_bytes':len(data)})).json()['data']
    assert rec['duration_ms']==0
    await client.post(f"/api/recordings/{rec['id']}/upload-file",files={'file':('audio.wav',data)})
    async with db.session_scope() as s:
        ident=(await s.scalars(select(AsrJob))).one().id
    await dispatcher.execute(ident)
    async with db.session_scope() as s:
        job=await s.get(AsrJob,ident)
        assert job.status==('completed' if complete else 'incomplete'),job.error


@pytest.mark.parametrize('version',[0,1])
def test_m4a_duration_and_malformed_container(tmp_path,version):
    def box(kind,data):return struct.pack('>I4s',len(data)+8,kind)+data
    mvhd=(b'\0'*12+struct.pack('>II',1000,90500)) if version==0 else (b'\x01'+b'\0'*19+struct.pack('>IQ',1000,90500))
    path=tmp_path/'audio.m4a'
    path.write_bytes(box(b'ftyp',b'M4A \0\0\0\0')+box(b'mdat',b'dummy')+box(b'moov',box(b'mvhd',mvhd)))
    assert audio_duration(path)==90.5
    path.write_bytes(path.read_bytes()[:-3])
    assert audio_duration(path) is None


async def test_recorded_course_delete_is_conflict_and_preserves_all_data(env):
    client,db,dispatcher,cfg,cid=env
    rid,rec=await upload(env)
    response=await client.delete(f'/api/courses/{cid}')
    assert response.status_code==409,response.text
    async with db.session_scope() as s:
        assert await s.get(Course,cid)
        assert await s.get(Recording,rid)
    assert Path(rec['file_path']).read_bytes()==b'test audio'
