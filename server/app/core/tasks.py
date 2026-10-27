"""任务队列抽象 + 进程内 asyncio 实现（架构设计 §1.3、§2.2 ``core/tasks.py``）。

MVP（单用户、单机）用进程内 asyncio 队列 + 单 Worker 协程；
抽象为 ``TaskQueue`` 接口，云端模式可换 Redis/Celery 后端（D-05）。
"""

from __future__ import annotations

import asyncio
from abc import ABC, abstractmethod
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Any

from app.core.ids import new_id, to_iso, utc_now

__all__ = [
    "TaskStatus",
    "TaskRecord",
    "TaskHandler",
    "TaskQueue",
    "AsyncioTaskQueue",
    "get_default_task_queue",
]


class TaskStatus(StrEnum):
    """任务状态。"""

    PENDING = "pending"
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"


TaskHandler = Callable[[dict[str, Any]], Awaitable[Any]]


@dataclass
class TaskRecord:
    """任务记录（内存态；长任务状态可持久化到 DB）。"""

    id: str
    name: str
    payload: dict[str, Any] = field(default_factory=dict)
    status: TaskStatus = TaskStatus.PENDING
    result: Any = None
    error: str | None = None
    created_at: datetime = field(default_factory=utc_now)
    started_at: datetime | None = None
    finished_at: datetime | None = None

    def to_dict(self) -> dict[str, Any]:
        """序列化为可 JSON 化字典。"""
        return {
            "id": self.id,
            "name": self.name,
            "status": self.status.value,
            "error": self.error,
            "created_at": to_iso(self.created_at),
            "started_at": to_iso(self.started_at) if self.started_at else None,
            "finished_at": to_iso(self.finished_at) if self.finished_at else None,
        }


class TaskQueue(ABC):
    """任务队列接口（云端可替换为外部 Broker 实现）。"""

    @abstractmethod
    async def start(self) -> None:
        """启动 Worker。"""

    @abstractmethod
    async def stop(self) -> None:
        """停止 Worker 并等待当前任务结束。"""

    @abstractmethod
    async def enqueue(
        self, name: str, handler: TaskHandler, payload: dict[str, Any] | None = None
    ) -> str:
        """入队一个任务，返回任务 ID。"""

    @abstractmethod
    async def get(self, task_id: str) -> TaskRecord | None:
        """查询任务记录。"""

    @abstractmethod
    async def list(self, status: TaskStatus | None = None) -> list[TaskRecord]:
        """列出任务（可按状态过滤）。"""

    @property
    @abstractmethod
    def worker_count(self) -> int:
        """Worker 数量。"""


class AsyncioTaskQueue(TaskQueue):
    """进程内 asyncio 单 Worker 队列实现。"""

    def __init__(self, max_concurrency: int = 1) -> None:
        self._max_concurrency = max(1, int(max_concurrency))
        self._queue: asyncio.Queue[tuple[str, TaskHandler, dict[str, Any]]] = asyncio.Queue()
        self._records: dict[str, TaskRecord] = {}
        self._workers: list[asyncio.Task[None]] = []
        self._running = False

    @property
    def worker_count(self) -> int:
        return len(self._workers)

    async def start(self) -> None:
        if self._running:
            return
        self._running = True
        for index in range(self._max_concurrency):
            worker = asyncio.create_task(self._run_worker(index), name=f"task-worker-{index}")
            self._workers.append(worker)

    async def stop(self) -> None:
        if not self._running:
            return
        self._running = False
        for _ in self._workers:
            await self._queue.put(("", self._sentinel, {}))
        await asyncio.gather(*self._workers, return_exceptions=True)
        self._workers.clear()

    @staticmethod
    async def _sentinel(_payload: dict[str, Any]) -> None:
        """哨兵任务：通知 Worker 退出。"""
        return None

    async def enqueue(
        self, name: str, handler: TaskHandler, payload: dict[str, Any] | None = None
    ) -> str:
        task_id = new_id("task")
        record = TaskRecord(id=task_id, name=name, payload=payload or {})
        self._records[task_id] = record
        await self._queue.put((task_id, handler, record.payload))
        return task_id

    async def get(self, task_id: str) -> TaskRecord | None:
        return self._records.get(task_id)

    async def list(self, status: TaskStatus | None = None) -> list[TaskRecord]:
        records = sorted(self._records.values(), key=lambda r: r.created_at, reverse=True)
        if status is None:
            return records
        return [r for r in records if r.status == status]

    async def _run_worker(self, worker_index: int) -> None:
        while True:
            task_id, handler, payload = await self._queue.get()
            if task_id == "":
                self._queue.task_done()
                return
            record = self._records.get(task_id)
            if record is not None:
                record.status = TaskStatus.RUNNING
                record.started_at = utc_now()
            try:
                result = await handler(payload)
                if record is not None:
                    record.status = TaskStatus.SUCCESS
                    record.result = result
            except Exception as exc:  # noqa: BLE001 - Worker 必须吞掉异常并记录
                if record is not None:
                    record.status = TaskStatus.FAILED
                    record.error = f"{exc.__class__.__name__}: {exc}"
            finally:
                if record is not None:
                    record.finished_at = utc_now()
                self._queue.task_done()


_QUEUE_SINGLETON: AsyncioTaskQueue | None = None


def get_default_task_queue() -> AsyncioTaskQueue:
    """进程内单例任务队列。"""
    global _QUEUE_SINGLETON
    if _QUEUE_SINGLETON is None:
        _QUEUE_SINGLETON = AsyncioTaskQueue()
    return _QUEUE_SINGLETON
