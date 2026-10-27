"""依赖注入 —— **唯一装配处**（架构设计 §1.4）。

业务代码只 ``Depends(get_xxx)``，**永不 import 具体 Provider 实现类**。
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from functools import lru_cache

from sqlalchemy.ext.asyncio import AsyncSession

from app.config import AppConfig, get_app_config
from app.core.tasks import AsyncioTaskQueue, get_default_task_queue
from app.db.session import Database, get_database, get_session
from app.providers.base import (
    LLMProvider,
    StorageProvider,
    TranscriptionProvider,
    VisionProvider,
)
from app.providers.registry import ProviderRegistry

__all__ = [
    "get_config",
    "get_registry",
    "get_db",
    "get_database_dep",
    "get_transcription_provider",
    "get_llm_provider",
    "get_vision_provider",
    "get_storage_provider",
    "get_note_store",
    "get_task_queue",
    "reset_deps",
]


def get_config() -> AppConfig:
    """返回全局配置（唯一读取入口）。"""
    return get_app_config()


@lru_cache(maxsize=1)
def get_registry() -> ProviderRegistry:
    """返回 Provider 工厂（单例，配置驱动）。"""
    return ProviderRegistry(get_app_config())


def get_transcription_provider() -> TranscriptionProvider:
    """按配置构建转写 Provider。"""
    return get_registry().build_transcription()


def get_llm_provider() -> LLMProvider:
    """按配置构建 LLM Provider。"""
    return get_registry().build_llm()


def get_vision_provider() -> VisionProvider:
    """按配置构建视觉 Provider。"""
    return get_registry().build_vision()


def get_storage_provider() -> StorageProvider:
    """按配置构建存储 Provider。"""
    return get_registry().build_storage()


def get_note_store() -> "NoteStore":
    """按部署模式装配 NoteStore 仓储端口（本地=Obsidian / 云端=对象存储）。"""
    from app.repositories.note_store import NoteStore  # noqa: F401
    from app.repositories.note_store_cloud import CloudNoteStore
    from app.repositories.note_store_local import ObsidianNoteStore

    config = get_app_config()
    db = get_database()
    if config.is_cloud:
        storage = get_storage_provider()
        return CloudNoteStore(config=config, database=db, storage_provider=storage)
    return ObsidianNoteStore(config=config, database=db)


def get_database_dep() -> Database:
    """返回数据库句柄。"""
    return get_database()


def get_task_queue() -> AsyncioTaskQueue:
    """返回进程内任务队列。"""
    return get_default_task_queue()


async def get_db() -> AsyncIterator[AsyncSession]:
    """FastAPI 依赖：提供自动提交/回滚的数据库会话。"""
    async for session in get_session():
        yield session


def reset_deps() -> None:
    """清空依赖单例缓存（供测试在切换配置后重建装配）。"""
    get_registry.cache_clear()
