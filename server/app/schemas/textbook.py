"""教材渲染、导览索引与回填数据传输模型（DTO）。"""

from __future__ import annotations

from pydantic import BaseModel, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "TextbookBackfillRequest",
    "TextbookBackfillResponse",
    "TextbookIndexEntryDTO",
    "TextbookIndexQuery",
    "TextbookRenderRequest",
    "TextbookRenderResponse",
]


class TextbookRenderRequest(StrictRequestModel):
    """请求渲染教材指定印刷页。"""

    course_name: str = Field(..., description="课程名称，如'线性代数'或'工程力学'")
    printed_pages: list[int] = Field(..., description="需要渲染的教材印刷页码列表")


class TextbookRenderResponse(BaseModel):
    """教材渲染结果。"""

    course_name: str
    rendered_images: list[str] = Field(
        default_factory=list, description="渲染出的临时 PNG 图片物理路径列表"
    )


class TextbookBackfillRequest(StrictRequestModel):
    """请求执行教材回填。"""

    note_id: str = Field(..., description="待回填的笔记稳定身份 note_id")
    course_name: str | None = Field(default=None, description="课程名称（可选，默认从笔记元数据读取）")


class TextbookBackfillResponse(BaseModel):
    """教材回填结果。"""

    note_id: str
    backfilled_items: list[str] = Field(
        default_factory=list, description="本次成功回填的要点说明"
    )
    marker_stats: dict[str, int] = Field(
        default_factory=dict, description="回填后更新的标记统计"
    )
    updated: bool = False


class TextbookIndexEntryDTO(StrictRequestModel):
    """教材知识点/例题索引条目（亦可作为新增索引条目的入参）。"""

    id: str | None = None
    course_name: str
    example_no: str | None = Field(default=None, description="例题编号，如'例 1.28'")
    summary: str = Field(..., description="知识点或例题概要")
    printed_page: int = Field(..., description="教材印刷页码")
    knowledge_point: str = Field(..., description="所属知识点")
    in_scope: bool = Field(default=True, description="是否在考纲/教学范围内")


class TextbookIndexQuery(StrictRequestModel):
    """教材索引查询参数。"""

    course_name: str
    knowledge_point: str | None = None
