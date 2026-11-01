"""Fail closed on unexpected automatic releases and emit safe version metadata."""
import os, re, subprocess
from pathlib import Path

PAT = re.compile(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$', re.M)
def parse(s):
    matches = PAT.findall(s)
    if len(matches) != 1:
        raise ValueError('pubspec must contain exactly one stable version+code')
    return tuple(map(int, matches[0]))

current = parse(Path('app/pubspec.yaml').read_text(encoding='utf-8'))
event = os.environ['GITHUB_EVENT_NAME']
mode = os.environ.get('RELEASE_MODE', '')
if os.environ['GITHUB_REF'] != 'refs/heads/main':
    raise ValueError('Release builds must target main')
if event == 'push':
    previous = os.environ.get('PUSH_BEFORE', '')
    if not re.fullmatch(r'[0-9a-f]{40}', previous) or previous == '0' * 40:
        raise ValueError('Missing push base; dispatch an explicit build instead')
    subprocess.run(['git', 'merge-base', '--is-ancestor', previous, 'HEAD'], check=True)
    old = parse(subprocess.check_output(['git', 'show', previous + ':app/pubspec.yaml'], text=True, encoding='utf-8'))
    if current == old:
        run = False
    elif current[:3] > old[:3] and current[3] > old[3]:
        run = True
    else:
        raise ValueError('Both version and build code must increase together')
    publish = run
elif event == 'workflow_dispatch' and mode in ('test', 'publish'):
    run, publish = True, mode == 'publish'
else:
    raise ValueError('Unsupported event or manual mode')
version = '.'.join(map(str, current[:3]))
with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as out:
    out.write(f'run={str(run).lower()}\npublish={str(publish).lower()}\nversion={version}\ncode={current[3]}\n')
print(f'Version {version}+{current[3]}, build={run}, publish={publish}')
