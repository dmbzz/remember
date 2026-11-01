"""Verify a prior run before reusing its exact retained build artifacts."""
import json, os, re, subprocess, urllib.request

run_id = os.environ['RECOVERY_RUN_ID']
version = os.environ['RECOVERY_VERSION']
if not re.fullmatch(r'[1-9][0-9]*', run_id) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise ValueError('A numeric run ID and stable version are required')
base = 'https://api.github.com/repos/' + os.environ['GITHUB_REPOSITORY']
headers = {'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'], 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'}
def get(path):
    request = urllib.request.Request(base + path, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)

run = get('/actions/runs/' + run_id)
if run.get('status') != 'completed' or run.get('event') != 'push' or run.get('head_branch') != 'main' or run.get('path', '').split('@')[0] != '.github/workflows/release.yml':
    raise ValueError('Run must be a completed push-triggered release workflow on main')
sha = run.get('head_sha', '')
if not re.fullmatch(r'[0-9a-f]{40}', sha):
    raise ValueError('Invalid source commit')
spec = subprocess.check_output(['git', 'show', sha + ':app/pubspec.yaml'], text=True, encoding='utf-8')
if len(re.findall(r'^version:\s*' + re.escape(version) + r'\+\d+\s*$', spec, re.M)) != 1:
    raise ValueError('Requested version does not match original run commit')
jobs = get('/actions/runs/' + run_id + '/jobs?per_page=100')['jobs']
if not any(j['name'] == 'build' and j['conclusion'] == 'success' for j in jobs):
    raise ValueError('Original build did not succeed')
assets = get('/actions/runs/' + run_id + '/artifacts?per_page=100')['artifacts']
matches = [a for a in assets if a['name'] == 'Remember-' + version and not a['expired']]
if len(matches) != 1:
    raise ValueError('Exact original build artifact missing, expired or ambiguous')
with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as out:
    out.write(f'source_sha={sha}\nversion={version}\n')
print('Original run and retained artifact verified:', run_id, version, sha)
