"""Per-job interruption and a publication barrier shared by API and worker thread."""
from __future__ import annotations

import threading
import time


class JobControl:
    def __init__(self, shutdown: threading.Event):
        self.shutdown = shutdown
        self.cancelled = threading.Event()
        self.lock = threading.Lock()
        self.publishing = False
        self.processes = {}
        self.stop_error = None

    def track_process(self, process, tree):
        with self.lock:
            self.processes[process.pid] = (process, tree)

    def process_stop_failed(self, message):
        with self.lock:
            self.stop_error = message

    def process_exited(self, process):
        with self.lock:
            self.processes.pop(process.pid, None)
            self.stop_error = None

    def is_set(self):
        return self.shutdown.is_set() or self.cancelled.is_set()

    def wait(self, timeout):
        deadline = time.monotonic() + timeout
        while not self.is_set():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            self.cancelled.wait(min(.1, remaining))
        return True

    def request_cancel(self):
        with self.lock:
            if self.publishing:
                return False
            self.cancelled.set()
            return True

    def begin_publish(self):
        with self.lock:
            if self.publishing:
                return
            if self.is_set():
                raise RuntimeError('转写已取消或中断，源录音保留')
            self.publishing = True


def check_interrupted(stop):
    if stop.is_set():
        raise RuntimeError('转写已取消或中断，源录音保留')


def begin_publish(stop):
    if hasattr(stop, 'begin_publish'):
        stop.begin_publish()
    else:
        check_interrupted(stop)
