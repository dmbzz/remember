import hashlib
import json
import subprocess
import threading
from pathlib import Path

import httpx
import pytest

from app import config
from app.services import asr_catalog as catalog
from app.services.asr_download import Downloads, Cancelled, safe_relative
from app.services.asr_model_manager import ModelManager, character_error_rate
from app.services.asr_settings import AsrSettings, load_settings, save_settings, validate_settings


@pytest.mark.parametrize('memory,driver,model,cuda', [
    (8192,'580.88','qwen-1.7b','cu128'),(4096,'566.12','qwen-0.6b','cu126'),
    (2048,'580.88','whisper-small','cu128'),(8192,'555.12','whisper-small',None)])
def test_gpu_recommendations(monkeypatch,memory,driver,model,cuda):
    monkeypatch.setattr(catalog.shutil,'which',lambda _: 'fake-smi')
    monkeypatch.setattr(catalog.subprocess,'run',lambda *a,**k: subprocess.CompletedProcess(a,0,f'0, Laptop RTX, {memory}, {memory}, {driver}\n'.encode()))
    result=catalog.detect_hardware()
    assert result['recommended_id']==model and result['cuda_runtime']==cuda
    assert result['gpus'][0]['memory_mb']==memory


def test_gpu_query_failure_is_unconfirmed(monkeypatch):
    monkeypatch.setattr(catalog.shutil,'which',lambda _: 'fake-smi')
    monkeypatch.setattr(catalog.subprocess,'run',lambda *a,**k: subprocess.CompletedProcess(a,1,b''))
    result=catalog.detect_hardware()
    assert not result['gpus'] and result['cuda_runtime'] is None
    assert '未确认' in result['message']


@pytest.mark.parametrize('value',['../x','/x','C:/x','a\\x','a//x','a/./x'])
def test_manifest_path_bounds(value):
    with pytest.raises(ValueError): safe_relative(value)


def downloader(handler):
    download=Downloads(threading.Event(),lambda **k:None)
    download.client.close()
    download.client=httpx.Client(transport=httpx.MockTransport(handler),follow_redirects=True)
    return download


@pytest.mark.parametrize('mode',['resume','reset','bad_full'])
def test_download_resume_and_corrupt_full_recovery(tmp_path,mode):
    target=tmp_path/'weights'
    partial=tmp_path/'weights.download'
    content=b'correct weight bytes'
    partial.write_bytes(content[:4] if mode!='bad_full' else b'x'*len(content))
    def handle(request):
        if mode=='resume':
            assert request.headers['range']=='bytes=4-'
            return httpx.Response(206,content=content[4:],headers={'Content-Range':f'bytes 4-{len(content)-1}/{len(content)}'})
        if mode=='bad_full': assert 'range' not in request.headers
        return httpx.Response(200,content=content)
    d=downloader(handle)
    try:d.fetch('https://vendor.test/model',target,size=len(content),sha=hashlib.sha256(content).hexdigest())
    finally:d.close()
    assert target.read_bytes()==content and not partial.exists()


def test_hash_failure_never_installs(tmp_path):
    d=downloader(lambda r:httpx.Response(200,content=b'wrong'))
    with pytest.raises(ValueError,match='校验失败'):
        d.fetch('https://vendor.test/model',tmp_path/'model',size=5,sha='0'*64)
    d.close()
    assert not (tmp_path/'model').exists()


def test_range_mismatch_is_rejected(tmp_path):
    (tmp_path/'model.download').write_bytes(b'123')
    d=downloader(lambda r:httpx.Response(206,content=b'456',headers={'Content-Range':'bytes 2-4/6'}))
    with pytest.raises(ValueError,match='范围'):d.fetch('https://vendor.test/model',tmp_path/'model',size=6)
    d.close()


def test_cancel_preserves_partial(tmp_path):
    d=downloader(lambda r:httpx.Response(200,content=b'ignored'))
    d.stop.set()
    with pytest.raises(Cancelled):d.fetch('https://vendor.test/model',tmp_path/'model')
    d.close()
    assert not (tmp_path/'model').exists()


def test_vendor_manifest_excludes_executable_code():
    files=[dict(rfilename='model.safetensors',size=3,lfs={'sha256':'a'*64}),
           dict(rfilename='config.json',size=3,blobId='b'*40),
           dict(rfilename='loader.py',size=3,blobId='b'*40),
           dict(rfilename='legacy.bin',size=3,blobId='b'*40)]
    d=downloader(lambda r:httpx.Response(200,json={'sha':'abc','siblings':files}))
    assert [v['path'] for v in d.model_manifest('Qwen/test','huggingface','qwen')]==['model.safetensors','config.json']
    d.close()


def test_interrupted_job_and_no_host_execution(tmp_path,monkeypatch):
    (tmp_path/'operation.json').write_text('{"id":"old","status":"dependencies"}')
    manager=ModelManager(tmp_path)
    assert manager.snapshot()['status']=='interrupted'
    monkeypatch.setattr(manager,'_install',lambda *a: (_ for _ in ()).throw(ValueError('test failed')))
    monkeypatch.setattr(manager,'hardware',lambda: {'cuda_runtime':None})
    manager.install('whisper-small');manager.thread.join(2)
    assert manager.snapshot()['status']=='failed'
    assert not list(tmp_path.glob('installed/*'))


def receipt(manager,verified=True):
    folder=manager.path('fake');folder.mkdir(parents=True,exist_ok=True)
    for file in ('python.exe','ffmpeg.exe'):(folder/file).write_bytes(b'not executable')
    value=dict(deployment_id='whisper-small-cpu',model_id='whisper-small',name='Whisper Small',engine='whisper',device='cpu',
               python_path=str(folder/'python.exe'),ffmpeg_path=str(folder/'ffmpeg.exe'),model_path=str(folder),aligner_path='',verified=verified)
    manager.path('installed').mkdir()
    manager.path('installed','whisper-small-cpu.json').write_text(json.dumps(value))
    return value


def test_activation_requires_audio_test_and_preserves_user_policy(tmp_path,monkeypatch):
    monkeypatch.setattr(config,'USER_CONFIG_FILE',tmp_path/'config.user.yaml')
    manager=ModelManager(tmp_path/'managed');value=receipt(manager,False)
    with pytest.raises(ValueError,match='真实音频'):manager.activate(value['deployment_id'])
    output=tmp_path/'output';output.mkdir()
    old=AsrSettings(output_dir=str(output),enabled=True,delete_source=True,api_key='private-test-only')
    save_settings(old)
    before=(tmp_path/'asr.user.json').read_bytes()
    with pytest.raises(ValueError):manager.activate(value['deployment_id'])
    assert (tmp_path/'asr.user.json').read_bytes()==before
    value['verified']=True
    manager.path('installed','whisper-small-cpu.json').write_text(json.dumps(value))
    manager.activate(value['deployment_id'])
    current=load_settings()
    assert current.enabled and current.delete_source and current.api_key==old.api_key
    assert current.output_dir==old.output_dir and current.mode=='local_whisper'


def test_receipt_outside_root_rejected(tmp_path):
    manager=ModelManager(tmp_path/'managed');value=receipt(manager)
    value['python_path']=str(tmp_path/'external.exe')
    (tmp_path/'external.exe').write_bytes(b'no')
    manager.path('installed','whisper-small-cpu.json').write_text(json.dumps(value))
    with pytest.raises(ValueError):manager.receipt(value['deployment_id'])


def test_failed_new_deployment_never_publishes_receipt_or_overwrites_settings(tmp_path,monkeypatch):
    from app.services import asr_model_manager
    monkeypatch.setattr(config,'USER_CONFIG_FILE',tmp_path/'config.user.yaml')
    output=tmp_path/'output';output.mkdir()
    save_settings(AsrSettings(output_dir=str(output),enabled=True,delete_source=True))
    before=(tmp_path/'asr.user.json').read_bytes()
    manager=ModelManager(tmp_path/'managed');old=receipt(manager)
    old_receipt=manager.path('installed','whisper-small-cpu.json').read_bytes()
    runtime=manager.path('runtime');runtime.mkdir()
    monkeypatch.setattr(manager,'hardware',lambda:dict(cuda_runtime=None,selected_gpu=0))
    monkeypatch.setattr(manager,'_runtime',lambda *a:runtime)
    def run(*a): (runtime/'ffmpeg-path.json').write_text(json.dumps(str(runtime/'ffmpeg.exe')))
    monkeypatch.setattr(manager,'_run',run)
    monkeypatch.setattr(manager,'_test',lambda *a,**k:(_ for _ in ()).throw(ValueError('real audio test failed')))
    class Download:
        def __init__(self,*a):pass
        def model_manifest(self,*a):return [dict(path='model.bin',size=3,sha='a'*64,git_sha=None,url='https://vendor.test/model')]
        def fetch(self,url,target,**kw):target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(b'new')
        def close(self):pass
    monkeypatch.setattr(asr_model_manager,'Downloads',Download)
    manager.install('whisper-small');manager.thread.join(2)
    assert manager.snapshot()['status']=='failed'
    assert (tmp_path/'asr.user.json').read_bytes()==before
    assert manager.path('installed','whisper-small-cpu.json').read_bytes()==old_receipt
    assert len(list(manager.path('installed').glob('*.json')))==1


@pytest.mark.parametrize('managed',[True,False])
def test_qwen_low_memory_profile_preserves_legacy_parameters(tmp_path,monkeypatch,managed):
    import sys
    from types import SimpleNamespace
    from app.services.qwen_worker import main
    calls=[]
    gpu_calls=[]
    def select_gpu(index):
        gpu_calls.append(('select', index))
    def reset_stats(index):
        assert gpu_calls == [('select', index)], 'GPU allocator not initialized before statistics'
        gpu_calls.append(('reset', index))
    torch=SimpleNamespace(float16='fp16',bfloat16='bf16',float32='fp32',set_num_threads=lambda n:None,
                          cuda=SimpleNamespace(set_device=select_gpu,reset_peak_memory_stats=reset_stats,max_memory_allocated=lambda _:1024**2))
    class Model:
        @staticmethod
        def from_pretrained(*a,**kw):calls.append(kw);return Model()
        def transcribe(self,**kw):return [SimpleNamespace(time_stamps=None,text='测试文本')]
    monkeypatch.setitem(sys.modules,'torch',torch)
    monkeypatch.setitem(sys.modules,'qwen_asr',SimpleNamespace(Qwen3ASRModel=Model))
    request=tmp_path/'request.json'
    request.write_text(json.dumps(dict(managed=managed,gpu_index=1,model_path='model',aligner_path='aligner',
        chunks=[dict(audio='test.wav',output=str(tmp_path/'out.json'),offset=0)])))
    main(str(request),'cuda')
    assert gpu_calls == [('select', 1), ('reset', 1)]
    assert calls[0]['dtype']==('fp16' if managed else 'bf16')
    assert calls[0]['max_inference_batch_size']==(1 if managed else 4)
    assert calls[0]['forced_aligner_kwargs']['device_map']==('cpu' if managed else 'cuda:1')


def test_cer_normalization():
    assert character_error_rate('你好，ABC！','你好 abc')==0
    assert character_error_rate('你好世界','你好世')==.25
    with pytest.raises(ValueError):character_error_rate('！','任何')


def test_managed_retry_never_reuses_other_models_or_legacy_twenty_minute_chunks(tmp_path,monkeypatch):
    import wave
    from types import SimpleNamespace
    from app.services import asr_engine,asr_model_manager
    work=tmp_path/'work';work.mkdir()
    with wave.open(str(work/'audio.wav'),'wb') as wav:
        wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(b'\0\0'*16000*61)
    (work/'c000.wav').write_bytes(b'old twenty minute shard')
    requests=[]
    def run(args,log,*a):
        if args[0]=='fake-ffmpeg':Path(args[-1]).write_bytes(b'new thirty second shard');return
        request=json.loads(Path(args[-2]).read_text('utf-8'));requests.append(request)
        assert args[1]=='-I'
        assert args[-1]=='cpu'
        for chunk in request['chunks']:
            assert Path(chunk['audio']).read_bytes()==b'new thirty second shard'
            Path(chunk['output']).write_text(json.dumps({'aligned':True,'device':'cpu','peak_vram_mb':0,
                'segments':[{'s':chunk['offset'],'e':min(chunk['offset']+30,61),'t':'课堂测试'}]}))
    monkeypatch.setattr(asr_engine,'run_process',run)
    monkeypatch.setattr(asr_model_manager,'get_model_manager',lambda:SimpleNamespace(receipt=lambda _:dict(device='cpu',gpu_index=0)))
    for identity in ('qwen-0.6b-cpu','whisper-small-cpu'):
        cfg=AsrSettings(managed_id=identity,mode='local_whisper' if identity.startswith('whisper') else 'local_qwen',
                        python_path='fake-python',ffmpeg_path='fake-ffmpeg',model_path=identity,model=identity)
        value=asr_engine.local_infer(tmp_path/'source',work,cfg,threading.Event())
        assert value['execution_device']=='cpu' and value['coverage_complete']
    assert requests[0]['chunks'][0]['output']!=requests[1]['chunks'][0]['output']
    assert len(requests[0]['chunks'])==3
    assert (work/'c000.wav').read_bytes()==b'old twenty minute shard'


@pytest.mark.parametrize('path,payload',[('/api/asr/models/install',{'model_id':'whisper-small'}),
    ('/api/asr/models/cancel',{}),('/api/asr/models/test',{'deployment_id':'whisper-small-cpu'}),
    ('/api/asr/models/activate',{'deployment_id':'whisper-small-cpu'})])
async def test_model_mutations_refuse_phone(tmp_path,monkeypatch,path,payload):
    from app.main import create_app
    from app.core.security import LanPairingMiddleware
    # Local-check is tested independently of pairing credentials.
    monkeypatch.setattr(LanPairingMiddleware,'dispatch',lambda self,request,call_next:call_next(request))
    app=create_app()
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app,client=('192.168.137.178',54321)),base_url='http://localhost') as client:
        response=await client.post(path,json=payload)
    assert response.status_code==401
    assert 'Windows' in response.json()['message']
