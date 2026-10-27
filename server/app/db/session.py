"""异步数据库会话（SQLite 本地 / Postgres 云端，同一套代码）。"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from functools import lru_cache

from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.config import get_app_config
from app.db.base import Base
from app.errors import ApiError, ErrorCode

__all__ = ["Database", "get_database", "get_session", "reset_database"]


class Database:
    """封装 async engine 与 session 工厂，屏蔽 SQLite/Postgres 差异。"""

    def __init__(self, db_url: str, *, echo: bool = False) -> None:
        self._db_url = db_url
        self._echo = echo
        self._engine: AsyncEngine | None = None
        self._session_factory: async_sessionmaker[AsyncSession] | None = None

    @property
    def db_url(self) -> str:
        return self._db_url

    def _ensure_engine(self) -> AsyncEngine:
        """惰性创建 engine（含方言驱动缺失时的友好错误）。"""
        if self._engine is not None:
            return self._engine
        connect_args: dict[str, object] = {}
        if self._db_url.startswith("sqlite"):
            connect_args["check_same_thread"] = False
            # 自动创建本地 SQLite 所在目录，防止路径不存在导致无法打开数据库文件
            db_path_str = self._db_url.split(":///", 1)[-1] if ":///" in self._db_url else ""
            if db_path_str and db_path_str != ":memory:":
                from pathlib import Path
                try:
                    Path(db_path_str).parent.mkdir(parents=True, exist_ok=True)
                except Exception:
                    pass
        try:
            self._engine = create_async_engine(
                self._db_url,
                echo=self._echo,
                future=True,
                pool_pre_ping=True,
                connect_args=connect_args,
            )
        except Exception as exc:  # noqa: BLE001 - 方言/驱动缺失统一转业务错误
            raise ApiError(
                ErrorCode.CONFIG_ERROR,
                f"无法创建数据库引擎（{self._db_url}）：{exc}",
            ) from exc
        return self._engine

    @property
    def engine(self) -> AsyncEngine:
        return self._ensure_engine()

    @property
    def session_factory(self) -> async_sessionmaker[AsyncSession]:
        """返回 session 工厂（惰性初始化）。"""
        if self._session_factory is None:
            self._session_factory = async_sessionmaker(
                bind=self.engine,
                expire_on_commit=False,
                autoflush=False,
            )
        return self._session_factory

    async def create_all(self) -> None:
        """按元数据建表（M0 用 create_all，M1 起引入 Alembic，见 D-07）。"""
        # 确保模型已注册到 Base.metadata
        from app.db import models  # noqa: F401

        async with self.engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)

    async def dispose(self) -> None:
        """释放连接池。"""
        if self._engine is not None:
            await self._engine.dispose()
            self._engine = None
            self._session_factory = None

    @asynccontextmanager
    async def session_scope(self) -> AsyncIterator[AsyncSession]:
        """事务上下文：异常自动回滚。"""
        session = self.session_factory()
        try:
            yield session
            await session.commit()
        except SQLAlchemyError:
            await session.rollback()
            raise
        finally:
            await session.close()


@lru_cache(maxsize=1)
def get_database() -> Database:
    """按当前配置构造并缓存 ``Database``。"""
    config = get_app_config()
    return Database(config.db_url, echo=config.db_echo)


def reset_database() -> None:
    """清空数据库单例缓存（供测试切换配置后重建）。"""
    get_database.cache_clear()


async def get_session() -> AsyncIterator[AsyncSession]:
    """FastAPI 依赖：提供一个自动提交/回滚的会话。"""
    database = get_database()
    async with database.session_factory() as session:
        try:
            yield session
            await session.commit()
        except SQLAlchemyError:
            await session.rollback()
            raise
