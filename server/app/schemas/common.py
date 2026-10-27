"""通用响应体与分页（架构设计 §7.2）。

统一响应体：``{"code": int, "data": T | None, "message": str}``，``code=0`` 表示成功。
"""

from __future__ import annotations

from typing import Any, Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

__all__ = [
    "ApiResponse",
    "ok",
    "PageParams",
    "PageMeta",
    "PagedData",
    "StrictRequestModel",
]

T = TypeVar("T")


class StrictRequestModel(BaseModel):
    """**请求（入参）模型基类**：禁止未知字段（``extra='forbid'``）。

    共享约定：所有 HTTP 入参 schema 继承本类。当调用方传入后端不认识的字段时，
    **立即返回 422**，而不是被 Pydantic 默认的 ``extra='ignore'`` 静默丢弃——
    这能防止「参数其实没生效、接口却回 200 成功」的静默失败
    （例如课程 ``auto_record`` 未落库时接口仍报「更新成功」）。

    注意：**响应模型（``*Response`` / ``*DTO``）不继承本类**——响应侧字段允许演进。
    """

    model_config = ConfigDict(extra="forbid")


class ApiResponse(BaseModel, Generic[T]):
    """统一 API 响应体。"""

    code: int = 0
    data: T | None = None
    message: str = "ok"


def ok(data: Any = None, message: str = "ok") -> dict[str, Any]:
    """构造成功响应字典（供路由直接返回）。"""
    return {"code": 0, "data": data, "message": message}


class PageParams(StrictRequestModel):
    """分页入参。"""

    page: int = Field(default=1, ge=1)
    size: int = Field(default=20, ge=1, le=200)

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.size


class PageMeta(BaseModel):
    """分页元信息。"""

    total: int = 0
    page: int = 1
    size: int = 20


class PagedData(BaseModel, Generic[T]):
    """分页数据体。"""

    items: list[T] = Field(default_factory=list)
    meta: PageMeta = Field(default_factory=PageMeta)
