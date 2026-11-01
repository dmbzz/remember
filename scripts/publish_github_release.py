"""Publish only a verified draft. Existing tags/assets are never overwritten."""
import hashlib, os, re, sys
from pathlib import Path
from urllib.parse import quote
import requests

repo = os.environ['GITHUB_REPOSITORY']
sha = os.environ['GITHUB_SHA']
version = os.environ['RELEASE_VERSION']
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{40}', sha):
    raise ValueError('Unsafe version or commit')
tag = 'v' + version
base = 'https://api.github.com/repos/' + repo
session = requests.Session()
session.headers.update({'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'],
                        'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'})
def call(method, url, **kw):
    response = session.request(method, url, timeout=(30, 600), **kw)
    if not response.ok:
        raise RuntimeError(f'GitHub API {method} failed: HTTP {response.status_code}')
    return response

def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def verify_ref():
    ref = call('GET', base + '/git/ref/tags/' + quote(tag, safe='')).json()['object']
    for _ in range(5):
        if ref['type'] == 'commit':
            if ref['sha'] != sha: raise ValueError('Release tag points to a different commit')
            return
        if ref['type'] != 'tag': raise ValueError('Unexpected tag object')
        ref = call('GET', base + '/git/tags/' + ref['sha']).json()['object']
    raise ValueError('Tag nesting too deep')

ref_url = base + '/git/ref/tags/' + quote(tag, safe='')
r = session.get(ref_url, timeout=30)
if r.status_code == 404:
    call('POST', base + '/git/refs', json={'ref':'refs/tags/'+tag, 'sha':sha})
elif not r.ok:
    raise RuntimeError(f'Tag lookup failed: HTTP {r.status_code}')
verify_ref()
releases = []
page = 1
while True:
    batch = call('GET', base + '/releases', params={'per_page':100, 'page':page}).json()
    releases.extend(batch)
    if len(batch) < 100: break
    page += 1
matches = [r for r in releases if r['tag_name'] == tag]
if len(matches) > 1: raise ValueError('Multiple releases with same tag')
if matches:
    release = matches[0]
else:
    release = call('POST', base+'/releases', json={'tag_name':tag, 'target_commitish':sha,
        'name':'Remember '+version, 'draft':True, 'prerelease':False,
        'body':'Android 安装包与 Windows 完整包。下载后可用 SHA256SUMS 校验文件完整性。'}).json()

folder = Path('dist')
files = [folder / f'Remember-{version}-Android.apk', folder / f'Remember-{version}-Windows-完整包.zip']
if any(not p.is_file() or not p.stat().st_size for p in files): raise ValueError('Missing release asset')
sums = folder/'SHA256SUMS.txt'
sums.write_text(''.join(f'{digest(p)}  {p.name}\n' for p in files),encoding='utf-8',newline='\n')
files.append(sums)
assets = []
page = 1
while True:
    batch = call('GET', base+f"/releases/{release['id']}/assets", params={'per_page':100, 'page':page}).json()
    assets.extend(batch)
    if len(batch) < 100: break
    page += 1
by_name = {a['name']:a for a in assets}
if len(by_name) != len(assets) or set(by_name) - {p.name for p in files}:
    raise ValueError('Unexpected or duplicate existing assets in draft')
for p in files:
    local = digest(p)
    asset = by_name.get(p.name)
    if asset is None:
        if not release['draft']:
            raise ValueError('Public release is missing an expected asset; refusing to alter it')
        upload = release['upload_url'].split('{',1)[0]
        with p.open('rb') as data:
            asset = call('POST', upload, params={'name':p.name}, data=data,
                         headers={'Content-Type':'application/octet-stream'}).json()
    response = call('GET', base+f"/releases/assets/{asset['id']}",
                    headers={'Accept':'application/octet-stream'}, stream=True)
    h = hashlib.sha256()
    size = 0
    for chunk in response.iter_content(1024*1024):
        h.update(chunk); size += len(chunk)
    response.close()
    if h.hexdigest() != local or size != p.stat().st_size:
        raise ValueError(f'Uploaded asset differs: {p.name}; existing assets are never overwritten')
    print('Downloaded and verified:', p.name, local)
verify_ref()
if release['draft']:
    call('PATCH', base+f"/releases/{release['id']}", json={'draft':False})
    print('Published verified release:', tag)
else:
    print('Existing public release verified:', tag)
