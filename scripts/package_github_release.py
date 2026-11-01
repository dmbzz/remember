"""Build the clean, relocatable Windows distribution from already-built inputs.

Only the public repository's server/app is copied. User configuration, audio,
note databases, keys, and other local state are rejected, never bundled.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import tempfile
import zipfile
from pathlib import Path

VERSION = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
PYTHON_DLL = re.compile(r"^python(3\d{2})\.dll$", re.I)
USER_PATH = re.compile(rb"(?i)[a-z]:[/\\]+users[/\\]+(?!<|\$)[^/\\\s\x27\x22]+[/\\]")
PRIVATE_KEY = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")
HANDOFF_PYTHON = re.compile(rb'(?i)[a-z]:[/\\]+users[/\\]+[^/\\\s\x27\x22]+[/\\]+\.workbuddy[/\\]+binaries[/\\]+python[/\\]+envs[/\\]+default[/\\]+scripts[/\\]+python\.exe')
API_TOKEN = re.compile(rb"(?:sk-[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9_]{30,})")
TEXT_SUFFIXES = {'.py', '.ps1', '.yaml', '.yml', '.md', '.txt', '.json', '.html', '.xml', '.ini', '.toml'}
PRIVATE_SUFFIXES = {'.db', '.sqlite', '.sqlite3', '.keystore', '.jks', '.p12', '.pfx', '.p8',
                    '.key', '.m4a', '.aac', '.wav', '.mp3', '.flac', '.ogg', '.opus', '.mp4'}
PRIVATE_NAMES = {'.env', 'pairing.json', 'config.user.yaml', 'desktop.user.json', 'asr.user.json',
                 'id_rsa', 'id_ed25519', 'credentials.json'}
SKIP_DIRS = {'__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache'}


def safe_server_text(path: Path, rel: Path) -> bytes:
    data = path.read_bytes()
    if rel.as_posix() == 'services/handoff_service.py':
        data = HANDOFF_PYTHON.sub(b'python', data)
    if USER_PATH.search(data) or PRIVATE_KEY.search(data) or API_TOKEN.search(data):
        raise ValueError(f'server application contains a personal path or secret: {rel}')
    return data


def checked_inputs(root: Path, *, scope: str):
    """Yield files before copying; never read a rejected secret or audio file."""
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f'{scope} must be a real directory: {root}')
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        if path.is_symlink():
            raise ValueError(f'{scope} contains a symbolic link: {rel}')
        if not path.is_file() or path.suffix.lower() in {'.pyc', '.pyo'}:
            continue
        name = path.name.lower()
        if name in PRIVATE_NAMES or '.user.' in name or path.suffix.lower() in PRIVATE_SUFFIXES:
            raise ValueError(f'{scope} contains a prohibited file: {rel}')
        # Python certifi's vendored public root certificates are not private keys.
        if path.suffix.lower() == '.pem' and rel.as_posix().lower() not in {
            'lib/site-packages/certifi/cacert.pem',
            'lib/site-packages/pip/_vendor/certifi/cacert.pem',
        }:
            raise ValueError(f'{scope} contains an unexpected PEM file: {rel}')
        if scope == 'server application' and path.suffix.lower() in TEXT_SUFFIXES:
            safe_server_text(path, rel)
        yield path, rel


def copy_inputs(source: Path, dest: Path, *, scope: str):
    for path, rel in checked_inputs(source, scope=scope):
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if scope == 'server application' and path.suffix.lower() in TEXT_SUFFIXES:
            target.write_bytes(safe_server_text(path, rel))
        else:
            shutil.copyfile(path, target)


def configure_runtime(runtime: Path):
    if not (runtime / 'python.exe').is_file():
        raise ValueError('Portable Python runtime/python.exe is missing')
    dlls = [(p, PYTHON_DLL.match(p.name)) for p in runtime.glob('python3*.dll')]
    dlls = [(p, m) for p, m in dlls if m]
    if len(dlls) != 1:
        raise ValueError('Expected exactly one python3XY.dll in the portable runtime')
    tag = dlls[0][1].group(1)
    archive = f'python{tag}.zip'
    if (runtime / archive).is_file():
        paths = [archive, '.']
    elif (runtime / 'Lib/os.py').is_file() and (runtime / 'DLLs').is_dir():
        paths = ['Lib', 'DLLs', '.']
    else:
        raise ValueError('Portable Python standard library is missing')
    for other in ('python._pth', 'python3._pth'):
        if (runtime / other).exists():
            raise ValueError(f'Unexpected Python path override: {other}')
    site = runtime / 'Lib/site-packages'
    for package in ('fastapi', 'uvicorn', 'sqlalchemy', 'aiosqlite'):
        if not (site / package / '__init__.py').is_file():
            raise ValueError(f'Bundled Python dependency is missing: {package}')
    # The executable lives in backend/runtime; server/app is a sibling directory.
    # The explicit path avoids relying on Python's CWD/environment in ._pth mode.
    (runtime / f'python{tag}._pth').write_text(
        '\n'.join([*paths, 'Lib/site-packages', '../server', 'import site', '']), encoding='utf-8')


def write_clean_config(target: Path, version: str):
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(f'''# Clean distribution; configure personal paths inside Remember.
deployment_mode: local
app_name: class_notes_assistant
version: "{version}"
host: "0.0.0.0"
port: 8000
auth_enabled: false
force_https: false
db_url: "sqlite+aiosqlite:///data/classnotes.db"
storage_backend: local_fs
storage_root: "data/storage"
recordings_root: "data/recordings"
obsidian_root: "data/notes"
textbook_root: "data/textbooks"
handoff_dir: "data/handoff"
log_level: INFO
log_format: json
''', encoding='utf-8')


def zip_tree(root: Path, destination: Path):
    """Stable entry ordering, metadata and compression for identical inputs."""
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(root.rglob('*'), key=lambda p: p.as_posix()):
            rel = Path('Remember') / path.relative_to(root)
            name = rel.as_posix() + ('/' if path.is_dir() else '')
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = ((0o40755 if path.is_dir() else 0o100644) << 16) | (0x10 if path.is_dir() else 0)
            info.compress_type = zipfile.ZIP_DEFLATED
            if path.is_dir():
                archive.writestr(info, b'')
            else:
                # Stream large archives; never materialize a second APK in RAM.
                with path.open('rb') as source, archive.open(info, 'w', force_zip64=True) as dest:
                    shutil.copyfileobj(source, dest, 1024 * 1024)


def package(repo: Path, windows: Path, runtime: Path, apk: Path, output: Path, version: str) -> Path:
    if not VERSION.fullmatch(version):
        raise ValueError('Version must be a safe semantic version without build metadata')
    for required in ('app.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat',
                     'data/flutter_assets/AssetManifest.bin'):
        if not (windows / required).is_file():
            raise ValueError(f'Windows release is incomplete: {required}')
    app = repo / 'server/app'
    if not (app / '__init__.py').is_file() or not (app / 'main.py').is_file():
        raise ValueError('Public server application is incomplete')
    if apk.is_symlink() or not apk.is_file() or not zipfile.is_zipfile(apk):
        raise ValueError('Android APK is missing or not a ZIP archive')
    with zipfile.ZipFile(apk) as archive:
        if 'AndroidManifest.xml' not in archive.namelist() or archive.testzip():
            raise ValueError('Android APK archive is incomplete or corrupt')
    launcher = repo / 'scripts/ci_run_server_hidden.ps1'
    if launcher.is_symlink() or not launcher.is_file():
        raise ValueError('Clean portable launcher is missing')
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve()
    destination = output / f'Remember-{version}-Windows-完整包.zip'
    if destination.exists():
        raise FileExistsError(f'Output already exists: {destination.name}')
    # Ensure automatic cleanup cannot escape the caller-specified output root.
    with tempfile.TemporaryDirectory(prefix='.remember-release-', dir=output) as temporary:
        temporary_path = Path(temporary).resolve()
        if not temporary_path.is_relative_to(output):
            raise ValueError('Temporary directory is outside the output directory')
        stage = temporary_path / 'Remember'
        stage.mkdir()
        copy_inputs(windows, stage, scope='Windows release')
        backend = stage / 'backend'
        copy_inputs(app, backend / 'server/app', scope='server application')
        copy_inputs(runtime, backend / 'runtime', scope='portable Python runtime')
        configure_runtime(backend / 'runtime')
        (backend / 'scripts').mkdir(parents=True)
        shutil.copyfile(launcher, backend / 'scripts/run_server_hidden.ps1')
        shutil.copyfile(apk, backend / '课堂学习助手.apk')
        requirements = repo / 'server/requirements-portable.txt'
        if not requirements.is_file() or requirements.is_symlink():
            raise ValueError('Portable backend requirements are missing')
        shutil.copyfile(requirements, backend / 'server/requirements-portable.txt')
        write_clean_config(backend / 'server/config/config.local.yaml', version)
        for name in ('notes', 'recordings', 'storage', 'textbooks', 'handoff'):
            (backend / 'server/data' / name).mkdir(parents=True, exist_ok=True)
        (stage / '开始使用.txt').write_text(
            f'Remember {version}\n\n解压整个文件夹到可写目录，双击 app.exe。\n'
            '在应用内设置笔记与录音目录。电脑和手机连接同一局域网后使用六位连接码。\n'
            '手机安装包位于 backend/课堂学习助手.apk。模型可在录音页按需下载。\n', encoding='utf-8')
        for filename in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            src = repo / filename
            if src.is_file() and not src.is_symlink():
                shutil.copyfile(src, stage / filename)
        for filename in ('应用内ASR模型部署.md', '六位连接码.md', '转写任务管理与最近记录-20261031.md'):
            src = repo / 'docs' / filename
            if src.is_file() and not src.is_symlink():
                # Reuse source text scanning before publishing additional docs.
                data = src.read_bytes()
                if USER_PATH.search(data) or PRIVATE_KEY.search(data) or API_TOKEN.search(data):
                    raise ValueError(f'Distribution guide contains a personal path or secret: {filename}')
                (stage / filename).write_bytes(data)
        temporary_zip = temporary_path / 'package.zip'
        zip_tree(stage, temporary_zip)
        with zipfile.ZipFile(temporary_zip) as archive:
            if archive.testzip():
                raise ValueError('Generated Windows package failed CRC validation')
        temporary_zip.replace(destination)
    with destination.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    (output / (destination.name + '.sha256')).write_text(f'{digest}  {destination.name}\n', encoding='utf-8')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('repo', 'windows-release', 'python-runtime', 'apk', 'output-dir'):
        parser.add_argument('--' + arg, type=Path, required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    result = package(args.repo, args.windows_release, args.python_runtime, args.apk, args.output_dir, args.version)
    print(f'Windows package: {result.name} ({result.stat().st_size} bytes)')


if __name__ == '__main__':
    main()
