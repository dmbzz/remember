"""笔记与转写检索相关 DTO。"""

from __future__ import annotations

from pydantic import BaseModel, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "ConsistencyReport",
    "SearchQuery",
    "SearchResultItem",
]


class SearchResultItem(BaseModel):
    """单条检索结果。"""

    rel_path: str
    title: str
    snippet: str
    score: float = 1.0
    course_name: str | None = None
    target_type: str = "note"  # note / transcript


class SearchQuery(StrictRequestModel):
    """检索请求参数。"""

    q: str = Field(..., description="检索关键词或题目题干")
    course: str | None = Field(default=None, description="课程名称过滤")
    limit: int = Field(default=10, description="最大返回结果数")


class ConsistencyReport(BaseModel):
    """索引一致性检查报告。"""

    total_indexed: int
    valid_count: int
    missing_count: int
    missing_files: list[str] = Field(default_factory=list)
