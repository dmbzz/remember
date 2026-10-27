"""交接包（Handoff）相关 DTO（对应 handoff.json schema，架构设计 §7.5）。"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field

from app.schemas.common import StrictRequestModel

__all__ = [
    "GenerateHandoffRequest",
    "TaskRef",
    "StageProgress",
    "HandoffJson",
    "HandoffFilesResponse",
]


class GenerateHandoffRequest(StrictRequestModel):
    """交接包生成入参。"""

    milestone: str = Field(default="M0", description="里程碑编号，如 M0")
    stage: str | None = Field(default=None, description="阶段名，如「项目地基」")


class TaskRef(BaseModel):
    """任务引用（done / in_progress / todo / blocked 通用条目）。"""

    task_id: str
    title: str
    artifacts: list[str] = Field(default_factory=list)
    owner: str | None = None
    blocker: str | None = None
    depends_on: list[str] = Field(default_factory=list)
    reason: str | None = None


class StageProgress(BaseModel):
    """阶段进度。"""

    completed_tasks: int = 0
    total_tasks: int = 0


class HandoffJson(BaseModel):
    """``handoff.json`` 的结构化 schema。

    ``conventions`` 与 ``environment_facts`` 由**代码常量固定注入**，
    禁止由 LLM 自由生成（架构设计 §7.5）。
    """

    schema_uri: str = Field(
        default="https://class_notes_assistant/schemas/handoff.schema.json", alias="$schema"
    )
    project: str = "class_notes_assistant"
    schema_version: str = "1.0"
    generated_at: str
    milestone: str
    stage: str
    stage_progress: StageProgress = Field(default_factory=StageProgress)
    summary: str = ""
    done: list[TaskRef] = Field(default_factory=list)
    in_progress: list[TaskRef] = Field(default_factory=list)
    todo: list[TaskRef] = Field(default_factory=list)
    blocked: list[TaskRef] = Field(default_factory=list)
    conventions: list[str] = Field(default_factory=list)
    decisions: list[dict[str, str]] = Field(default_factory=list)
    key_paths: dict[str, str] = Field(default_factory=dict)
    environment_facts: list[str] = Field(default_factory=list)

    model_config = {"populate_by_name": True}


class HandoffFilesResponse(BaseModel):
    """GET /api/handoff 返回的四份文件概览。"""

    agents: str = ""
    project_state: str = ""
    handoff_json: dict[str, Any] = Field(default_factory=dict)
    adrs: list[str] = Field(default_factory=list)
