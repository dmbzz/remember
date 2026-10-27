"""通用仓储（Repository）—— 面向 ORM 模型的异步 CRUD。"""

from __future__ import annotations

from typing import Any, Generic, TypeVar

from sqlalchemy import delete as sa_delete
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.base import Base

__all__ = ["BaseRepository", "ModelT"]

ModelT = TypeVar("ModelT", bound=Base)


class BaseRepository(Generic[ModelT]):
    """针对单一 ORM 模型的通用异步仓储。

    子类只需声明 ``model`` 类属性即可获得全部方法，避免每张表重复样板。
    """

    model: type[ModelT]

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get(self, obj_id: str) -> ModelT | None:
        """按主键取单条。"""
        return await self.session.get(self.model, obj_id)

    async def list(self, *, limit: int | None = None, offset: int = 0, **filters: Any) -> list[ModelT]:
        """按等值条件查询列表。"""
        stmt = select(self.model)
        for field, value in filters.items():
            stmt = stmt.where(getattr(self.model, field) == value)
        stmt = stmt.offset(max(0, offset))
        if limit is not None:
            stmt = stmt.limit(max(0, limit))
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def add(self, obj: ModelT) -> ModelT:
        """新增对象并 flush（获取主键）。"""
        self.session.add(obj)
        await self.session.flush()
        return obj

    async def add_all(self, objs: list[ModelT]) -> list[ModelT]:
        """批量新增。"""
        self.session.add_all(objs)
        await self.session.flush()
        return objs

    async def delete(self, obj: ModelT) -> None:
        """删除对象。"""
        await self.session.delete(obj)

    async def delete_by_id(self, obj_id: str) -> int:
        """按主键删除，返回受影响行数。"""
        result = await self.session.execute(
            sa_delete(self.model).where(self.model.id == obj_id)
        )
        return int(result.rowcount or 0)

    async def count(self, **filters: Any) -> int:
        """按等值条件计数。"""
        stmt = select(func.count()).select_from(self.model)
        for field, value in filters.items():
            stmt = stmt.where(getattr(self.model, field) == value)
        result = await self.session.execute(stmt)
        return int(result.scalar_one())
