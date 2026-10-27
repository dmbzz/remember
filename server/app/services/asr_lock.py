"""Cross-process Qwen lock shared with the existing daily scanner."""
from contextlib import contextmanager
import os
import threading


@contextmanager
def engine_lock(stop=None):
    stop = stop or threading.Event()
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        kernel.CreateMutexW.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel.WaitForSingleObject.restype = wintypes.DWORD
        kernel.ReleaseMutex.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.CreateMutexW(None, False, "Local\\ClassNotesQwenASR")
        if not handle:
            raise OSError(ctypes.get_last_error(), "无法创建 Qwen 互斥锁")
        owned = False
        try:
            while not stop.is_set():
                state = kernel.WaitForSingleObject(handle, 500)
                if state in (0, 0x80):
                    owned = True
                    break
                if state != 0x102:
                    raise OSError("无法等待 Qwen 互斥锁")
            if not owned:
                raise RuntimeError("已中止等待 Qwen 引擎")
            yield
        finally:
            if owned:
                kernel.ReleaseMutex(handle)
            kernel.CloseHandle(handle)
    else:
        import fcntl
        import tempfile
        from pathlib import Path
        with (Path(tempfile.gettempdir()) / f"classnotes-qwen-{os.getuid()}.lock").open("a") as handle:
            while True:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if stop.wait(.5):
                        raise RuntimeError("已中止等待 Qwen 引擎")
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)
