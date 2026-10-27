"""交接包路由（FR-16）：生成 / 查看 / 读取文件。"""

from __future__ import annotations

import json
from pathlib import Path

from fastapi import APIRouter, Depends

from app.config import AppConfig
from app.deps import get_config, get_llm_provider
from app.errors import ApiError, ErrorCode
from app.schemas.common import ok
from app.schemas.handoff import GenerateHandoffRequest
from app.services.handoff_service import HandoffService

__all__ = ["router"]

router = APIRouter(tags=["handoff"])


def _service(config: AppConfig) -> HandoffService:
    """构建交接包服务（LLM 不可用时自动降级为确定性总结）。"""
    try:
        llm = get_llm_provider()
    except Exception:  # noqa: BLE001 - LLM 装配失败不应阻断交接包生成
        llm = None
    return HandoffService(config, llm_provider=llm)


@router.post("/handoff/generate", summary="生成/覆写交接包四份文件")
async def generate_handoff(
    payload: GenerateHandoffRequest,
    config: AppConfig = Depends(get_config),
) -> dict:
    """生成交接包：``AGENTS.md`` / ``PROJECT_STATE.md`` / ``handoff.json`` / ``decisions/ADR-*.md``。"""
    service = _service(config)
    result = await service.generate(milestone=payload.milestone, stage=payload.stage)
    return ok(result)


@router.get("/handoff", summary="查看交接包概览")
async def read_handoff(config: AppConfig = Depends(get_config)) -> dict:
    """返回四类文件内容概览。"""
    output_dir = config.resolved_handoff_dir
    agents = _read_text(output_dir / "AGENTS.md")
    project_state = _read_text(output_dir / "PROJECT_STATE.md")
    handoff_json: dict = {}
    json_file = output_dir / "handoff.json"
    if json_file.exists():
        try:
            handoff_json = json.loads(json_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            handoff_json = {}
    decisions_dir = output_dir / "decisions"
    adrs = (
        sorted(p.name for p in decisions_dir.glob("ADR-*.md")) if decisions_dir.exists() else []
    )
    return ok(
        {
            "agents": agents,
            "project_state": project_state,
            "handoff_json": handoff_json,
            "adrs": adrs,
            "output_dir": str(output_dir),
        }
    )


@router.get("/handoff/files/{name:path}", summary="读取交接包单个文件内容")
async def read_handoff_file(name: str, config: AppConfig = Depends(get_config)) -> dict:
    """读取交接包内单个文件（禁止目录穿越）。"""
    output_dir = config.resolved_handoff_dir
    target = (output_dir / name).resolve()
    base = output_dir.resolve()
    if base != target and base not in target.parents:
        raise ApiError(ErrorCode.NOT_FOUND, f"非法路径：{name}")
    if not target.exists() or not target.is_file():
        raise ApiError(ErrorCode.NOT_FOUND, f"文件不存在：{name}")
    return ok({"name": name, "content": target.read_text(encoding="utf-8")})


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""
