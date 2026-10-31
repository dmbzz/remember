"""Delete only a verified job's original audio; never consume replacement files."""
from __future__ import annotations

import hashlib
import os
import stat
from pathlib import Path


def _verify(stream, expected_hash, expected_size, expected_mtime):
    info = os.fstat(stream.fileno())
    if not stat.S_ISREG(info.st_mode) or info.st_size != expected_size or info.st_mtime != expected_mtime:
        raise ValueError('电脑录音已被替换或修改，未删除文件')
    if hashlib.file_digest(stream, 'sha256').hexdigest() != expected_hash:
        raise ValueError('电脑录音内容已变化，未删除文件')
    return info


def delete_verified_audio(source: Path, root: Path, expected_hash: str,
                          expected_size: int, expected_mtime: float) -> bool:
    """Return False when already absent. Windows locks identity through deletion."""
    if not source.is_absolute() or source.is_symlink():
        raise ValueError('录音路径不安全，未删除文件')
    resolved = source.resolve()
    if not resolved.is_relative_to(root.resolve()) or resolved == root.resolve():
        raise ValueError('录音不在当前电脑录音保存目录内，未删除文件')
    if not source.exists():
        return False
    if os.name == 'nt':
        return _delete_windows(resolved, expected_hash, expected_size, expected_mtime)
    # Non-Windows servers still reject symlinks and changed inode/metadata.
    descriptor = os.open(resolved, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(descriptor, 'rb') as stream:
        info = _verify(stream, expected_hash, expected_size, expected_mtime)
        current = resolved.stat(follow_symlinks=False)
        if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != (
                info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns):
            raise ValueError('录音路径已变化，未删除文件')
        resolved.unlink()
    return True


def _delete_windows(source, expected_hash, expected_size, expected_mtime):
    import ctypes
    import msvcrt
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.SetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.SetFileInformationByHandle.restype = wintypes.BOOL
    # GENERIC_READ | DELETE; share reads only: deny concurrent writes/replacement.
    handle = kernel.CreateFileW(str(source), 0x80000000 | 0x10000, 1, None, 3, 0x00200000, None)
    if handle == wintypes.HANDLE(-1).value:
        code = ctypes.get_last_error()
        if code in (2, 3):
            return False
        raise OSError(code, '录音正被使用或无法锁定，未删除文件')
    try:
        descriptor = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except Exception:
        kernel.CloseHandle(handle)
        raise
    with os.fdopen(descriptor, 'rb') as stream:
        _verify(stream, expected_hash, expected_size, expected_mtime)
        # FileDispositionInfo deletes this locked handle, not a later path occupant.
        remove = ctypes.c_ubyte(1)
        if not kernel.SetFileInformationByHandle(handle, 4, ctypes.byref(remove), ctypes.sizeof(remove)):
            raise OSError(ctypes.get_last_error(), '电脑录音删除失败')
    return True
