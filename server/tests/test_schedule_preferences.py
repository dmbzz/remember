from pathlib import Path
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from app.main import create_app
from app.db.base import Base
from app.deps import get_db
from app.services.schedule_preferences import TimetablePreferences

@pytest.fixture
async def client(tmp_path: Path):
    engine=create_async_engine(f'sqlite+aiosqlite:///{tmp_path / "schedule.db"}')
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    factory=async_sessionmaker(engine,expire_on_commit=False)
    app=create_app()
    async def db():
        async with factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise
    app.dependency_overrides[get_db]=db
    async with AsyncClient(transport=ASGITransport(app=app),base_url='http://test') as value:
        yield value
    await engine.dispose()

def prefs(count=10):
    data=TimetablePreferences().model_dump(mode='json')
    if count==12:data['slots'] += [{'start':'21:15','end':'22:00'},{'start':'22:10','end':'22:55'}]
    return data

def entry(**changes):
    return {'revision':0,'course_name':'工程力学','weekday':1,'start_slot':1,'end_slot':2,'weeks':[1,3,5],**changes}

@pytest.mark.asyncio
async def test_shared_settings_persist_and_revision_conflict(client):
    initial=(await client.get('/api/schedule/settings')).json()['data']
    assert initial['revision']==0 and not initial['configured']
    data=prefs(12);data.update(semester_weeks=20,first_week_odd=False,default_rule='even')
    result=await client.put('/api/schedule/settings',json={'revision':0,'settings':data})
    assert result.status_code==200,result.text
    saved=(await client.get('/api/schedule/settings')).json()['data']
    assert saved['settings']==data and saved['revision']==1
    assert (await client.put('/api/schedule/settings',json={'revision':0,'settings':prefs()})).status_code==409
    assert (await client.get('/api/schedule/settings')).json()['data']==saved

@pytest.mark.asyncio
@pytest.mark.parametrize('invalid',[
    {'slots':[{'start':'09:00','end':'08:00'}]},
    {'slots':[{'start':'25:00','end':'25:50'}]},
    {'slots':[{'start':'08:00','end':'09:00'},{'start':'08:55','end':'09:45'}]},
    {'semester_start':'2026-09-01'}, {'slots':[]}, {'semester_weeks':0}
])
async def test_invalid_settings_never_persist(client,invalid):
    result=await client.put('/api/schedule/settings',json={'revision':0,'settings':{**prefs(),**invalid}})
    assert result.status_code==422,result.text
    assert (await client.get('/api/schedule/settings')).json()['data']['revision']==0

@pytest.mark.asyncio
async def test_atomic_manual_create_edit_and_snapshot(client):
    response=await client.post('/api/schedule/manual',json=entry())
    assert response.status_code==200,response.text
    record=response.json()['data'];assert record['start_time']=='08:15' and record['end_time']=='09:50'
    assert record['weeks']==[1,3,5] and record['weeks_bitmap']==21
    edited=await client.post('/api/schedule/manual',json=entry(entry_id=record['id'],course_id=record['course_id'],course_name=None,weeks=[2,4,6]))
    assert edited.status_code==200,edited.text
    snapshot=(await client.get('/api/schedule/snapshot')).json()['data']
    assert snapshot['entries'][0]['weeks']==[2,4,6]
    assert len(snapshot['courses'])==1 and snapshot['preferences']['revision']==0
    assert (await client.get('/api/schedule?week=3')).json()['data']==[]
    assert len((await client.get('/api/schedule?week=4')).json()['data'])==1

@pytest.mark.asyncio
@pytest.mark.parametrize('invalid',[
    {'weeks':[]},{'weeks':[0]},{'weeks':[31]},{'weeks':[True]},
    {'start_slot':3,'end_slot':1},{'end_slot':11},
    {'start_time':'14:00','end_time':'13:00'},
    {'entry_id':'missing'}, {'course_id':'missing','course_name':None}
])
async def test_failed_manual_does_not_create_orphan_course(client,invalid):
    response=await client.post('/api/schedule/manual',json=entry(**invalid))
    assert response.status_code in [404,422],response.text
    assert (await client.get('/api/courses')).json()['data']==[]
    assert (await client.get('/api/schedule')).json()['data']==[]

@pytest.mark.asyncio
async def test_apply_slots_by_actual_endpoints_and_shrink_guard(client):
    first=await client.put('/api/schedule/settings',json={'revision':0,'settings':prefs(12)})
    assert first.status_code==200,first.text
    night=(await client.post('/api/schedule/manual',json=entry(revision=1,start_slot=11,end_slot=12))).json()['data']
    custom=(await client.post('/api/schedule/manual',json=entry(revision=1,course_name='独立时间',start_time='12:00',end_time='12:45'))).json()['data']
    rejected=await client.put('/api/schedule/settings',json={'revision':1,'settings':prefs(),'apply_to_entries':True})
    assert rejected.status_code==409,rejected.text
    assert (await client.get('/api/schedule/settings')).json()['data']['revision']==1
    new=prefs(12);new['slots'][10]={'start':'21:20','end':'22:00'}
    result=await client.put('/api/schedule/settings',json={'revision':1,'settings':new,'apply_to_entries':True})
    assert result.status_code==200,result.text
    snapshot=(await client.get('/api/schedule/snapshot')).json()['data']
    records={r['id']:r for r in snapshot['entries']}
    assert records[night['id']]['start_time']=='21:20'
    assert records[custom['id']]['start_time']=='12:00'
    assert (await client.post('/api/schedule/manual',json=entry(revision=1))).status_code==409
    shrink=await client.put('/api/schedule/settings',json={'revision':2,'settings':prefs(),'apply_to_entries':False})
    assert shrink.status_code==200
    assert len((await client.get('/api/schedule')).json()['data'])==2

@pytest.mark.asyncio
async def test_twentieth_lesson_is_supported(client):
    data=prefs();data['slots']=[{'start':f'{7+i//2:02d}:{30*(i%2):02d}', 'end':f'{7+i//2:02d}:{30*(i%2)+20:02d}'} for i in range(20)]
    assert (await client.put('/api/schedule/settings',json={'revision':0,'settings':data})).status_code==200
    response=await client.post('/api/schedule/manual',json=entry(revision=1,start_slot=20,end_slot=20))
    assert response.status_code==200,response.text

@pytest.mark.asyncio
async def test_server_today_honors_shared_semester_end_without_deleting_old_weeks(client):
    created=(await client.post('/api/schedule/manual',json=entry())).json()['data']
    config=prefs();config['semester_weeks']=2
    assert (await client.put('/api/schedule/settings',json={'revision':0,'settings':config})).status_code==200
    today=await client.get('/api/schedule/today?target_date=2026-09-14')
    assert today.status_code==200,today.text
    assert today.json()['data']['items']==[]
    assert (await client.get('/api/schedule')).json()['data'][0]['weeks']==created['weeks']
