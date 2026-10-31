"""HTTPS-only vendor downloads, bounded files, resumable bytes, and model manifests."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
from urllib.parse import quote
import httpx

class Cancelled(RuntimeError):
    pass

def safe_relative(name):
    path = PurePosixPath(name)
    if not name or '\\' in name or ':' in name or path.is_absolute() or any(p in ('', '.', '..') for p in name.split('/')):
        raise ValueError('下载清单包含不安全路径')
    return path

def file_sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

class Downloads:
    def __init__(self, stop, report):
        self.stop, self.report = stop, report
        self.client = httpx.Client(follow_redirects=True, trust_env=True, timeout=httpx.Timeout(60, connect=20))

    def close(self):
        self.client.close()

    def check(self):
        if self.stop.is_set(): raise Cancelled('已取消；下载分片保留，可重新下载继续')

    def json(self, url):
        self.check()
        if not url.startswith('https://'): raise ValueError('只允许 HTTPS 下载')
        response = self.client.get(url)
        response.raise_for_status()
        if len(response.content) > 20 * 1024 * 1024: raise ValueError('下载清单过大')
        return response.json()

    def fetch(self, url, target, *, size=None, sha=None, git_sha=None, base=0, total=None):
        self.check()
        if not url.startswith('https://'): raise ValueError('只允许 HTTPS 下载')
        target = Path(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        def valid(path):
            if not path.is_file() or (size is not None and path.stat().st_size != size): return False
            if sha: return file_sha(path) == sha
            if git_sha:
                data = path.read_bytes()
                return hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest() == git_sha
            return False
        if valid(target):
            self.report(received_bytes=base + target.stat().st_size, total_bytes=total or size)
            return
        partial = target.with_name(target.name + '.download')
        offset = partial.stat().st_size if partial.exists() else 0
        if size is not None and offset > size:
            partial.unlink(); offset = 0
        if size is not None and offset == size:
            if valid(partial):
                partial.replace(target); return
            partial.unlink(); offset = 0
        headers = {'Range': f'bytes={offset}-'} if offset else {}
        with self.client.stream('GET', url, headers=headers) as response:
            response.raise_for_status()
            if response.url.scheme != 'https': raise ValueError('下载地址降级为非 HTTPS，已停止')
            if offset and response.status_code == 206:
                if not response.headers.get('content-range', '').startswith(f'bytes {offset}-'):
                    raise ValueError('服务器续传范围不匹配，请重试')
            else:
                offset = 0
            advertised = response.headers.get('content-length')
            expected = size if size is not None else int(advertised) + offset if advertised else None
            if expected and expected > 8 * 1024**3: raise ValueError('单文件超过下载上限')
            with partial.open('ab' if offset else 'wb') as f:
                for chunk in response.iter_bytes(1024 * 1024):
                    self.check()
                    f.write(chunk); offset += len(chunk)
                    if offset > (size if size is not None else 8 * 1024**3): raise ValueError('下载超过清单大小')
                    self.report(received_bytes=base + offset, total_bytes=total or expected)
        if expected is not None and offset != expected: raise ValueError('下载中断，文件不完整，可重试续传')
        if (sha or git_sha) and not valid(partial):
            partial.unlink(missing_ok=True)
            raise ValueError('下载内容校验失败，未部署该文件，请重试')
        partial.replace(target)

    def model_manifest(self, repo, channel, engine):
        if channel == 'modelscope':
            raw = self.json(f'https://modelscope.cn/api/v1/models/{repo}/repo/files?Revision=master&Recursive=true')
            if raw.get('Code') != 200: raise ValueError('ModelScope 未返回模型文件清单')
            files = []
            for value in raw['Data']['Files']:
                if value.get('Type') != 'blob': continue
                name = value['Path']; safe_relative(name)
                files.append(dict(path=name, size=int(value['Size']), sha=value.get('Sha256'), git_sha=None,
                    url=f'https://modelscope.cn/api/v1/models/{repo}/repo?Revision={quote(value["Revision"])}&FilePath={quote(name, safe="")}'))
        else:
            host = 'https://hf-mirror.com' if channel == 'hf_mirror' else 'https://huggingface.co'
            raw = self.json(f'{host}/api/models/{repo}?blobs=true')
            revision = raw['sha']; files = []
            for value in raw['siblings']:
                name = value['rfilename']; safe_relative(name)
                lfs = value.get('lfs', {})
                files.append(dict(path=name, size=int(value.get('size', lfs.get('size', 0))), sha=lfs.get('sha256'),
                    git_sha=None if lfs else value.get('blobId'),
                    url=f'{host}/{repo}/resolve/{revision}/{quote(name, safe="/")}'))
        selected = []
        for value in files:
            name = value['path']
            if '/' in name: continue
            allowed = name.endswith(('.json', '.txt', '.safetensors', '.model')) or name in ('merges.txt', 'LICENSE', 'README.md')
            if engine == 'whisper' and name == 'model.bin': allowed = True
            if allowed:
                if value['size'] <= 0 or value['size'] > 8 * 1024**3: raise ValueError('模型清单大小异常')
                if not value['sha'] and not value['git_sha']: raise ValueError('模型清单缺少内容校验值')
                selected.append(value)
        if not any(v['path'].endswith('.safetensors') if engine == 'qwen' else v['path'] == 'model.bin' for v in selected):
            raise ValueError('模型清单缺少所需权重')
        if len(selected) > 200 or sum(v['size'] for v in selected) > 12 * 1024**3: raise ValueError('模型清单超过上限')
        return selected

