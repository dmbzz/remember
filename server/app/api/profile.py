"""课程与课表配置清单（Profile & Presets）API 路由。"""

from __future__ import annotations

from typing import Literal
from fastapi import APIRouter, Depends, File, Query, Response, UploadFile
import yaml
from sqlalchemy.ext.asyncio import AsyncSession

from app.deps import get_db
from app.errors import ApiError, ErrorCode
from app.schemas.common import ok
from app.schemas.schedule import (
    CurriculumProfile,
    ProfileImportRequest,
)
from app.services.profile_service import ProfileService

__all__ = ["router"]

router = APIRouter(tags=["profile"])


@router.get("/schedule/presets", summary="获取所有内置专业开箱模板")
async def list_presets(session: AsyncSession = Depends(get_db)) -> dict:
    """列出系统内置的所有专业课表模板（机械、计算机、电气、通识等）。"""
    service = ProfileService(session)
    items = service.list_presets()
    return ok([i.model_dump() for i in items])


@router.get("/schedule/presets/{preset_id}", summary="查看指定预设模板详情")
async def get_preset(preset_id: str, session: AsyncSession = Depends(get_db)) -> dict:
    """获取指定预设的全部课程与排课清单。"""
    service = ProfileService(session)
    preset = service.get_preset(preset_id)
    return ok(preset.model_dump())


@router.post("/schedule/presets/{preset_id}/apply", summary="一键应用专业预设")
async def apply_preset(
    preset_id: str,
    mode: Literal["replace", "merge"] = Query("replace", description="导入模式"),
    session: AsyncSession = Depends(get_db),
) -> dict:
    """一键套用指定专业的开箱课程与排课清单。"""
    service = ProfileService(session)
    result = await service.apply_preset(preset_id, mode=mode)
    return ok(result, message=f"已成功套用预设 '{preset_id}'")


@router.get("/schedule/time-slots", summary="获取高校常用节次作息时间表模板")
async def get_time_slots(session: AsyncSession = Depends(get_db)) -> dict:
    """列出常见高校作息模版（08:30大节制、08:00标准制、单小节45分钟等）。"""
    service = ProfileService(session)
    templates = service.get_time_slot_templates()
    return ok({k: v.model_dump() for k, v in templates.items()})


@router.post("/schedule/profile/import", summary="导入学期配置清单（JSON）")
async def import_profile(
    payload: ProfileImportRequest,
    session: AsyncSession = Depends(get_db),
) -> dict:
    """导入通用学期配置清单，批量创建/更新全部课程与上课时间安排。"""
    service = ProfileService(session)
    result = await service.import_profile(payload.profile, mode=payload.mode)
    return ok(result, message="配置清单导入成功")


@router.post("/schedule/profile/upload", summary="上传 YAML/JSON 清单文件导入")
async def upload_profile_file(
    file: UploadFile = File(..., description="YAML 或 JSON 配置文件"),
    mode: Literal["replace", "merge"] = Query("replace"),
    session: AsyncSession = Depends(get_db),
) -> dict:
    """上传学生或班委分享的 .yaml 或 .json 配置文件，一键完成整学期配置。"""
    content = await file.read()
    text = content.decode("utf-8")
    try:
        data = yaml.safe_load(text)
        profile = CurriculumProfile.model_validate(data)
    except Exception as exc:
        raise ApiError(ErrorCode.VALIDATION_ERROR, f"无法解析配置文件：{exc}") from exc

    service = ProfileService(session)
    result = await service.import_profile(profile, mode=mode)
    return ok(result, message="配置文件解析并导入成功")


@router.get("/schedule/profile/export", summary="导出当前学期课表配置清单（JSON）")
async def export_profile_json(
    semester: str | None = Query(None, description="指定学期"),
    session: AsyncSession = Depends(get_db),
) -> dict:
    """导出当前学期的全部课程与课表为 JSON 格式配置清单。"""
    service = ProfileService(session)
    profile = await service.export_profile(semester)
    return ok(profile.model_dump(exclude_none=True))


@router.get("/schedule/profile/export-yaml", summary="导出当前学期课表配置清单（YAML）")
async def export_profile_yaml(
    semester: str | None = Query(None, description="指定学期"),
    session: AsyncSession = Depends(get_db),
) -> Response:
    """导出当前学期配置为 YAML 文本格式，可直接下载或分享给同学。"""
    service = ProfileService(session)
    yaml_text = await service.export_profile_yaml(semester)
    return Response(
        content=yaml_text,
        media_type="application/x-yaml",
        headers={
            "Content-Disposition": f"attachment; filename=curriculum_{semester or 'default'}.yaml"
        },
    )
