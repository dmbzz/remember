"""作业搜题与解题交叉比对数据传输模型（DTO）。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "HomeworkSolveRequest",
    "RouteSolution",
    "SolutionRecordDTO",
]


class HomeworkSolveRequest(StrictRequestModel):
    """作业搜题请求。"""

    stem: str | None = Field(default=None, description="题目文字题干与条件")
    image_base64: str | None = Field(default=None, description="题目图片 Base64 编码")
    image_path: str | None = Field(default=None, description="题目图片本地物理路径")
    course: str | None = Field(default=None, description="课程名称（如'理论力学'、'自动控制原理'）")


class RouteSolution(BaseModel):
    """单一路线的解题结果结构。"""

    method_name: str = Field(..., description="解法名称，如'动能定理法'或'拉格朗日方程法'")
    steps: list[str] = Field(default_factory=list, description="详细分步推导过程")
    conclusion: str = Field(..., description="最终答案与数值结论")
    analysis: str = Field(default="", description="方法依据与为什么这么做")


class SolutionRecordDTO(BaseModel):
    """解答记录快照（三方交叉比对，绝对单一结论，ADR-004）。"""

    id: str
    question_id: str
    course: str | None = None
    stem: str
    teacher_route: dict[str, Any] = Field(default_factory=dict, description="老师路线解答")
    ai_independent: dict[str, Any] = Field(default_factory=dict, description="AI 独立解校验")
    compare_result: str = Field(..., description="比对状态：一致 / 冲突")
    conflict_reason: str | None = Field(default=None, description="冲突深层机理（若有）")
    final_conclusion: str = Field(..., description="唯一最终结论（严禁两种都对）")
    cited_note_paths: list[str] = Field(default_factory=list, description="引用的笔记路径清单")
    created_at: datetime
