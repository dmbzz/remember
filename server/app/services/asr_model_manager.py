"""Private ASR environments and resumable vendor models; never alter the host Python."""
from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
import httpx

from app.services.atomic_files import atomic_json
from app.services.asr_catalog import CATALOG, detect_hardware, model_by_id
from app.services.asr_download import Cancelled, Downloads

ACTIVE = {'preparing', 'environment', 'dependencies', 'downloading', 'verifying', 'waiting_engine', 'testing'}
SAMPLE_URL = 'https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-ASR-Repo/asr_zh.wav'
SAMPLE_SHA = '46dbc998c9d1d48111267c40741dd3200f2e5bcf4075f8c4c97f4451160dce50'

def models_root():
    configured = os.environ.get('CNA_ASR_MODEL_ROOT')
    return Path(configured).resolve() if configured else (
        Path(os.environ.get('LOCALAPPDATA', str(Path.home() / 'AppData/Local'))) / 'ClassNotesAssistant/asr-models').resolve()

def _safe_error(error):
    text = re.sub(r'https?://[^\s\"\']+', '[下载地址]', str(error))
    return text[-1600:] or type(error).__name__

class ModelManager:
    def __init__(self, root=None):
        self.root = Path(root or models_root()).resolve()
        self.lock = threading.RLock()
        self.stop = threading.Event()
        self.thread = None
        self.state = {}
        self._saved = 0.0
        self._hardware = None
        self._hardware_at = 0
        state = self.root / 'operation.json'
        if state.is_file():
            try:
                self.state = json.loads(state.read_text('utf-8'))
                if self.state.get('status') in ACTIVE:
                    self.state.update(status='interrupted', error='上次操作因程序退出中断；可重新点击下载或测试继续。')
            except (OSError, ValueError):
                self.state = {}

    def path(self, *parts):
        value = self.root.joinpath(*parts)
        if not value.resolve().is_relative_to(self.root):
            raise ValueError('应用内模型目录已变化，请检查目录权限')
        return value

    def snapshot(self):
        with self.lock:
            return json.loads(json.dumps(self.state))

    def report(self, **values):
        with self.lock:
            old = self.state.get('status')
            self.state.update(values)
            if 'status' in values and values['status'] != old:
                self.state['received_bytes'] = values.get('received_bytes')
                self.state['total_bytes'] = values.get('total_bytes')
            now = time.monotonic()
            if self.state and (now - self._saved >= .3 or self.state.get('status') != old or 'error' in values or 'result' in values):
                self.root.mkdir(parents=True, exist_ok=True)
                atomic_json(self.path('operation.json'), self.state)
                self._saved = now

    def hardware(self, refresh=False):
        if refresh or self._hardware is None or time.monotonic() - self._hardware_at > 60:
            self._hardware, self._hardware_at = detect_hardware(), time.monotonic()
        return self._hardware

    def receipt(self, deployment):
        if not re.fullmatch(r'(qwen-0\.6b|qwen-1\.7b|whisper-turbo|whisper-small)-(cpu|cu126|cu128)(-[a-f0-9]{12})?', deployment):
            raise ValueError('无效的应用内模型部署编号')
        value = json.loads(self.path('installed', deployment + '.json').read_text('utf-8'))
        model_by_id(value['model_id'])
        for name in ('python_path', 'model_path', 'ffmpeg_path'):
            location = Path(value[name])
            if not location.resolve().is_relative_to(self.root) or not location.exists():
                raise ValueError('已部署模型文件不完整，请重新下载修复')
        if value.get('aligner_path') and (not Path(value['aligner_path']).resolve().is_relative_to(self.root) or not Path(value['aligner_path']).is_dir()):
            raise ValueError('模型对齐路径不属于本应用')
        return value

    def catalog(self, refresh=False):
        installed = []
        folder = self.path('installed')
        if folder.exists():
            for file in folder.glob('*.json'):
                try:
                    value = self.receipt(file.stem)
                    installed.append({k: value.get(k) for k in ('deployment_id','model_id','name','device','verified','last_test')})
                except (ValueError, OSError, KeyError):
                    pass
        return dict(models=CATALOG, hardware=self.hardware(refresh), installations=installed, operation=self.snapshot(),
                    storage_path=str(self.root), channels=[{'id':'auto','name':'自动选择'},
                    {'id':'modelscope','name':'ModelScope（Qwen 国内渠道）'}, {'id':'huggingface','name':'Hugging Face'}, {'id':'hf_mirror','name':'HF 镜像（第三方）'}])

    def cancel(self):
        self.stop.set()
        return self.snapshot()

    def _start(self, operation, ident, callback):
        with self.lock:
            if self.thread and self.thread.is_alive():
                raise ValueError('已有下载或测试正在进行，请等待完成或取消')
            self.stop = threading.Event()
            self.state = dict(id=uuid.uuid4().hex, kind=operation, model_id=ident,
                              status='preparing', error=None, received_bytes=None, total_bytes=None, result=None)
            self.report(status='preparing', error=None)
            def work():
                try:
                    callback()
                except Cancelled as error:
                    self.report(status='cancelled', error=str(error))
                except Exception as error:
                    self.report(status='cancelled' if self.stop.is_set() else 'failed', error=_safe_error(error))
            self.thread = threading.Thread(target=work, name='remember-asr-model-operation', daemon=True)
            self.thread.start()
            return self.snapshot()

    def install(self, ident, channel='auto', device='auto'):
        model = model_by_id(ident)
        if channel not in ('auto','modelscope','huggingface','hf_mirror') or device not in ('auto','cpu'):
            raise ValueError('无效的下载渠道或设备选项')
        if channel == 'modelscope' and not model['ms']:
            raise ValueError('此模型未提供 ModelScope 渠道，请选择自动或 Hugging Face')
        hardware = self.hardware()
        flavor = hardware['cuda_runtime'] if device == 'auto' and hardware.get('cuda_runtime') else 'cpu'
        return self._start('install', ident, lambda: self._install(model, channel, flavor, hardware))

    def _run(self, args, log, timeout=7200):
        if self.stop.is_set(): raise Cancelled('操作已取消，可重新下载继续')
        log.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, PYTHONUTF8='1', PYTHONUNBUFFERED='1', PIP_DISABLE_PIP_VERSION_CHECK='1',
                   HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', PYTHONNOUSERSITE='1', PIP_CONFIG_FILE=os.devnull)
        for key in ('PYTHONPATH','PYTHONHOME','PYTHONUSERBASE'):
            env.pop(key,None)
        with log.open('ab') as output:
            process = subprocess.Popen([str(a) for a in args], stdout=output, stderr=subprocess.STDOUT,
                env=env, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            start = time.monotonic()
            try:
                while process.poll() is None:
                    if self.stop.wait(.25): raise Cancelled('操作已取消，可重新下载继续')
                    if time.monotonic() - start > timeout: raise RuntimeError('环境准备超时，可重新下载继续')
                if process.returncode:
                    tail = log.read_bytes()[-3500:].decode('utf-8', errors='replace')
                    raise RuntimeError('环境操作失败：' + _safe_error(tail))
            finally:
                if process.poll() is None:
                    if os.name == 'nt':
                        subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'], capture_output=True,
                                       creationflags=subprocess.CREATE_NO_WINDOW, timeout=20)
                    else: process.kill()
                process.wait(timeout=30)

    def _runtime(self, engine, flavor, channel):
        version = f'{sys.version_info.major}{sys.version_info.minor}'
        key = f'{engine}-{flavor}-py{version}-v3'
        target = self.path('runtimes', key)
        marker = target / 'ready.json'
        if marker.exists():
            return target
        if os.name != 'nt' or sys.version_info[:2] not in ((3,11),(3,12),(3,13)):
            raise ValueError('应用内部署需要 Windows 64 位与 Python 3.11–3.13 应用运行时')
        self.report(status='environment')
        target.mkdir(parents=True, exist_ok=True)
        base = Path(sys.base_prefix)
        if not (target/'base-ready.json').exists():
            # Copy the application's base interpreter and standard library ONLY.
            # Never copy site-packages or the host's ROCm/CUDA/Python environment.
            for name in ('python.exe','pythonw.exe','LICENSE.txt'):
                if (base/name).is_file(): shutil.copy2(base/name, target/name)
            for file in base.glob('*.dll'): shutil.copy2(file, target/file.name)
            for file in base.glob('python*.zip'): shutil.copy2(file, target/file.name)
            for folder in ('Lib','DLLs'):
                if (base/folder).is_dir():
                    shutil.copytree(base/folder,target/folder,dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('site-packages','__pycache__','test','tests','idlelib','tkinter'))
            (target/'Lib/site-packages').mkdir(parents=True,exist_ok=True)
            pth = list(base.glob('python*._pth'))
            if pth:
                (target/pth[0].name).write_text(f'python{version}.zip\n.\nLib\nLib/site-packages\nimport site\n','utf-8')
            atomic_json(target/'base-ready.json',{'python':sys.version.split()[0]})
        python = target/'python.exe'
        if not python.is_file(): raise ValueError('应用运行时不完整，无法准备私有 Python；请使用完整 Windows 安装包')
        # pip itself is application tooling; copying its vendored bootstrap avoids
        # a second installer or any writes into the user's existing Python.
        if not (target/'Lib/site-packages/pip').exists():
            spec = importlib.util.find_spec('pip')
            if not spec or not spec.submodule_search_locations: raise ValueError('应用安装包缺少 pip 工具，请使用完整安装包')
            shutil.copytree(next(iter(spec.submodule_search_locations)),target/'Lib/site-packages/pip')
        self.report(status='dependencies')
        index = 'https://pypi.org/simple' if channel == 'huggingface' else 'https://pypi.tuna.tsinghua.edu.cn/simple'
        common = [python,'-I','-X','utf8','-m','pip','install','--prefer-binary','--progress-bar','off','--retries','2','--timeout','30']
        log = target/'install.log'
        if engine == 'qwen' or flavor != 'cpu':
            self._run(common+['torch==2.7.1','--index-url',f'https://download.pytorch.org/whl/{flavor}'],log)
        packages = (['qwen-asr==0.0.6'] if engine == 'qwen' else ['faster-whisper==1.2.1','ctranslate2==4.6.0','av==16.0.1']) + ['huggingface-hub==0.36.2','imageio-ffmpeg==0.6.0','setuptools==80.9.0']
        self._run(common+packages+['--index-url',index],log)
        self._run([python,'-c','import ssl,ctypes,imageio_ffmpeg; '+('import torch,qwen_asr' if engine=='qwen' else 'import faster_whisper,ctranslate2')],log,120)
        atomic_json(marker,dict(engine=engine,flavor=flavor,python=sys.version.split()[0]))
        return target

    def _install(self, model, channel, flavor, hardware):
        source = 'modelscope' if channel == 'auto' and model['ms'] else 'hf_mirror' if channel == 'auto' else channel
        download = Downloads(self.stop, self.report)
        try:
            if shutil.disk_usage(self.root.parent).free < (model['download_gb'] + (8 if flavor!='cpu' else 3)) * 1024**3:
                raise ValueError('可用磁盘空间不足，请先释放空间再下载')
            runtime = self._runtime(model['engine'],flavor,channel)
            self.report(status='downloading')
            repositories = [(model['ms'] if source=='modelscope' else model['hf'], model['id'])]
            if model['engine']=='qwen': repositories.append(('Qwen/Qwen3-ForcedAligner-0.6B','qwen-aligner'))
            manifests=[]
            for repo, folder in repositories:
                try:
                    manifest=download.model_manifest(repo,source,model['engine'])
                except (httpx.HTTPError,ValueError):
                    if channel!='auto' or source!='modelscope': raise
                    source='hf_mirror'
                    repo=model['hf'] if folder==model['id'] else repo
                    manifest=download.model_manifest(repo,source,model['engine'])
                manifests.append((folder,manifest))
            total=sum(v['size'] for _,items in manifests for v in items); base=0
            folders={}
            for folder, items in manifests:
                # Content-addressed folders preserve any currently selected model.
                digest=hashlib.sha256(json.dumps([(v['path'],v['size'],v['sha'],v['git_sha']) for v in items],sort_keys=True).encode()).hexdigest()[:16]
                folders[folder]=self.path('weights',folder+'-'+digest)
                for value in items:
                    download.fetch(value['url'],folders[folder]/value['path'],size=value['size'],sha=value['sha'],git_sha=value['git_sha'],base=base,total=total)
                    base+=value['size']
            self.report(status='verifying')
            probe=runtime/'ffmpeg-path.json'
            self._run([runtime/'python.exe','-c',f'import json,imageio_ffmpeg;json.dump(imageio_ffmpeg.get_ffmpeg_exe(),open({str(probe)!r},"w"))'],runtime/'install.log',60)
            revision=hashlib.sha256((str(folders[model['id']])+'|'+str(runtime)).encode()).hexdigest()[:12]
            deployment=model['id']+'-'+flavor+'-'+revision
            value=dict(deployment_id=deployment,model_id=model['id'],name=model['name'],engine=model['engine'],
                device='cpu' if flavor=='cpu' else 'cuda',gpu_index=hardware.get('selected_gpu',0),
                python_path=str(runtime/'python.exe'),ffmpeg_path=json.loads(probe.read_text('utf-8')),
                model_path=str(folders[model['id']]),
                aligner_path=str(folders['qwen-aligner']) if model['engine']=='qwen' else '',
                verified=False,source=source)
            self.path('installed').mkdir(exist_ok=True)
            self.report(deployment_id=deployment)
            result=self._test(value,download=download)
            value.update(verified=True,last_test=result)
            atomic_json(self.path('installed',deployment+'.json'),value)
            self.report(status='ready',result=result,error=None)
        finally:
            download.close()

    def test(self, deployment, audio=None, reference=''):
        value=self.receipt(deployment)
        return self._start('test',value['model_id'],lambda:self._finish_test(value,audio,reference))

    def _finish_test(self,value,audio,reference):
        try:
            result=self._test(value,audio,reference)
            value.update(verified=True,last_test=result)
            atomic_json(self.path('installed',value['deployment_id']+'.json'),value)
            self.report(status='ready',deployment_id=value['deployment_id'],result=result,error=None)
        finally:
            if audio and Path(audio).resolve().is_relative_to(self.path('test-inputs').resolve()):
                Path(audio).unlink(missing_ok=True)

    def _test(self,value,audio=None,reference='',download=None):
        from app.services.asr_engine import infer, run_process
        from app.services.asr_lock import engine_lock
        from app.services.asr_settings import AsrSettings
        own=download is None
        download=download or Downloads(self.stop,self.report)
        try:
            if audio is None:
                self.report(status='downloading')
                audio=self.path('samples','asr-zh.wav')
                # Official fixed Chinese demo. The managed test never archives/deletes user audio.
                download.fetch(SAMPLE_URL,audio,size=134570,sha=SAMPLE_SHA)
            folder=self.path('tests',self.state['id']);folder.mkdir(parents=True,exist_ok=True)
            source=folder/'sample.wav'
            self.report(status='verifying')
            run_process([value['ffmpeg_path'],'-y','-i',str(audio),'-vn','-ac','1','-ar','16000','-t','61',str(source)],folder/'decode.log',self.stop,120)
            import wave
            with wave.open(str(source),'rb') as wav: duration=wav.getnframes()/wav.getframerate()
            if duration<=0 or duration>60.05: raise ValueError('请选择不超过 60 秒的短录音进行测试')
            cfg=AsrSettings(mode='local_qwen' if value['engine']=='qwen' else 'local_whisper',
                python_path=value['python_path'],model_path=value['model_path'],aligner_path=value['aligner_path'],
                ffmpeg_path=value['ffmpeg_path'],model=value['name'],managed_id=value['deployment_id'])
            self.report(status='waiting_engine')
            start=time.monotonic()
            with engine_lock(self.stop):
                self.report(status='testing')
                result=infer(source,folder/'inference',cfg,self.stop,managed_override=value)
            if self.stop.is_set(): raise Cancelled('音频测试已取消；原配置保留')
            text=''.join(s['t'] for s in result['segments']).strip()
            if not text: raise ValueError('测试未识别出文字；请检查音频或换一个模型')
            output=dict(text=text,duration_sec=round(duration,2),elapsed_sec=round(time.monotonic()-start,2),
                        device=result.get('execution_device','未确认'),peak_vram_mb=result.get('peak_vram_mb'),segments=len(result['segments']))
            if reference.strip(): output['cer']=character_error_rate(reference,text)
            return output
        finally:
            if own: download.close()

    def activate(self,deployment):
        from app.services.asr_settings import load_settings,save_settings,AsrSettings
        value=self.receipt(deployment)
        if not value.get('verified'): raise ValueError('请先完成一次真实音频测试，再使用该模型')
        old=load_settings()
        output=old.output_dir or str(self.path('transcripts'))
        Path(output).mkdir(parents=True,exist_ok=True)
        data=old.model_dump()
        data.update(mode='local_qwen' if value['engine']=='qwen' else 'local_whisper',model=value['name'],managed_id=deployment,
            python_path=value['python_path'],model_path=value['model_path'],aligner_path=value['aligner_path'],ffmpeg_path=value['ffmpeg_path'],output_dir=output)
        configured=AsrSettings.model_validate(data)
        save_settings(configured)
        return configured

def character_error_rate(reference,actual):
    def normalize(value): return ''.join(c.lower() for c in value if c.isalnum())
    target,source=normalize(reference),normalize(actual)
    if not target: raise ValueError('参考文字至少需要一个汉字、字母或数字')
    if len(target)>10000 or len(source)>10000: raise ValueError('测试参考文字过长')
    previous=list(range(len(source)+1))
    for i,a in enumerate(target,1):
        row=[i]
        for j,b in enumerate(source,1): row.append(min(row[-1]+1,previous[j]+1,previous[j-1]+(a!=b)))
        previous=row
    return round(previous[-1]/len(target),4)

_managers={}
_manager_lock=threading.Lock()

def stop_model_operations():
    with _manager_lock:
        managers=list(_managers.values())
    for manager in managers:
        manager.stop.set()
    for manager in managers:
        if manager.thread and manager.thread.is_alive():
            manager.thread.join(timeout=25)
def get_model_manager():
    root=models_root()
    with _manager_lock:
        if str(root) not in _managers: _managers[str(root)]=ModelManager(root)
        return _managers[str(root)]
