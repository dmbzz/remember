"""Keep exact child-process handles until a stopped Windows worker tree exits."""
import os
import subprocess


class ProcessStopFailed(RuntimeError):
    """Stopping was requested, but process exit is not yet confirmed."""


class ProcessTree:
    def __init__(self, process):
        self.process = process
        self.children = {}
        if os.name == 'nt':
            import ctypes
            from ctypes import wintypes
            self.ctypes, self.types = ctypes, wintypes
            self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            self.kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
            self.kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
            self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            self.kernel.OpenProcess.restype = wintypes.HANDLE
            self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            self.kernel.WaitForSingleObject.restype = wintypes.DWORD
            self.kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
            self.kernel.TerminateProcess.restype = wintypes.BOOL
            self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]

    def refresh(self):
        if os.name != 'nt':
            return
        c, w, kernel = self.ctypes, self.types, self.kernel
        class Entry(c.Structure):
            _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('pid', w.DWORD),
                        ('heap', c.c_size_t), ('module', w.DWORD), ('threads', w.DWORD),
                        ('parent', w.DWORD), ('priority', w.LONG), ('flags', w.DWORD),
                        ('name', w.WCHAR * 260)]
        kernel.Process32FirstW.argtypes = [w.HANDLE, c.POINTER(Entry)]
        kernel.Process32NextW.argtypes = [w.HANDLE, c.POINTER(Entry)]
        kernel.Process32FirstW.restype = kernel.Process32NextW.restype = w.BOOL
        snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
        if snapshot == w.HANDLE(-1).value:
            raise ProcessStopFailed('无法确认转写子进程列表，继续等待停止')
        try:
            entry = Entry(size=c.sizeof(Entry))
            found = []
            c.set_last_error(0)
            more = kernel.Process32FirstW(snapshot, c.byref(entry))
            while more:
                found.append((entry.pid, entry.parent))
                more = kernel.Process32NextW(snapshot, c.byref(entry))
            if c.get_last_error() != 18:  # ERROR_NO_MORE_FILES
                raise ProcessStopFailed('无法完整读取转写子进程列表，继续等待停止')
            # Popen retains the root HANDLE; retained descendant HANDLEs also
            # keep their identities alive after exit. Discover orphan children
            # even if a parent exited between snapshot and stop confirmation.
            roots = {self.process.pid, *self.children}
            while True:
                descendants = {pid for pid, parent in found if parent in roots and pid not in roots}
                if not descendants:
                    break
                for pid in descendants:
                    if pid not in self.children:
                        handle = kernel.OpenProcess(0x100001, False, pid)
                        if handle:
                            self.children[pid] = handle
                        elif c.get_last_error() not in (87,):
                            raise ProcessStopFailed('无法锁定转写子进程身份，继续等待停止')
                roots.update(descendants)
        finally:
            kernel.CloseHandle(snapshot)

    def stop_children(self):
        if os.name == 'nt':
            for handle in self.children.values():
                if self.kernel.WaitForSingleObject(handle, 0) == 258:
                    # A retained HANDLE cannot target a later process reusing this PID.
                    if not self.kernel.TerminateProcess(handle, 1):
                        if self.kernel.WaitForSingleObject(handle, 0) != 0:
                            raise ProcessStopFailed('转写子进程尚未停止，继续等待确认')

    def confirmed(self):
        return self.process.poll() is not None and (os.name != 'nt' or all(
            self.kernel.WaitForSingleObject(handle, 0) == 0 for handle in self.children.values()))

    def close(self):
        if os.name == 'nt':
            for handle in self.children.values():
                self.kernel.CloseHandle(handle)
        self.children.clear()


def stop_owned_process(process, tree, timeout=30):
    tree.refresh()
    error = None
    if process.poll() is None:
        try:
            if os.name == 'nt':
                result = subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                    capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW, timeout=20)
                if result.returncode != 0:
                    error = ProcessStopFailed(f'停止命令返回 {result.returncode}，尚未确认转写进程退出')
            else:
                process.kill()
        except (OSError, subprocess.TimeoutExpired) as exc:
            error = ProcessStopFailed(f'停止命令未完成，继续等待退出：{type(exc).__name__}')
    tree.stop_children()
    if process.poll() is None:
        if error:
            raise error
        try:
            process.wait(timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ProcessStopFailed('转写进程退出尚未确认，继续等待停止') from exc
    # Re-snapshot after parent exit too: a child may have been created between
    # the first snapshot and taskkill's own tree enumeration.
    tree.refresh()
    if not tree.confirmed():
        raise ProcessStopFailed('转写进程树尚未全部退出，继续等待停止')
