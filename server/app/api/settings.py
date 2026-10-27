from pathlib import Path
import ipaddress
from typing import Any

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict

from app.config import AppConfig, save_user_config
from app.deps import get_config, get_registry, reset_deps
from app.errors import ApiError, ErrorCode
from app.providers.base import BaseProvider
from app.providers.registry import ProviderRegistry
from app.schemas.common import ok
from app.schemas.obsidian import (
    ObsidianInitRequest,
    ObsidianInitResponse,
    ObsidianPathStatusDTO,
    ObsidianPathValidateRequest,
)
from app.schemas.provider import (
    ProviderConfigUpdate,
    ProviderInfo,
    from_app_config,
)
from app.services.obsidian_service import ObsidianService

__all__ = ["router"]

router = APIRouter(tags=["settings"])


class LocalPathsUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    obsidian_root: str | None = None
    recordings_root: str | None = None


def _require_local(request: Request, config: AppConfig) -> None:
    host = request.client.host if request.client else ""
    try:
        local = ipaddress.ip_address(host).is_loopback
    except ValueError:
        local = False
    if not local or config.deployment_mode != "local":
        raise ApiError(ErrorCode.UNAUTHORIZED, "保存路径只能在 Windows 电脑本机设置")


@router.get("/settings/local-paths", summary="读取 Windows 笔记与录音目录")
async def get_local_paths(request: Request, config: AppConfig = Depends(get_config)) -> dict:
    _require_local(request, config)
    return ok({"obsidian_root": config.obsidian_root,
               "recordings_root": str(config.resolved_recordings_root)})


@router.put("/settings/local-paths", summary="设置 Windows 笔记与录音目录")
async def set_local_paths(payload: LocalPathsUpdate, request: Request,
                          config: AppConfig = Depends(get_config)) -> dict:
    _require_local(request, config)
    updates = payload.model_dump(exclude_none=True)
    if not updates:
        raise ApiError(ErrorCode.VALIDATION_ERROR, "请选择要设置的目录")
    for key, raw in updates.items():
        path = Path(raw.strip()).expanduser()
        if not path.is_absolute() or not path.is_dir():
            raise ApiError(ErrorCode.VALIDATION_ERROR, f"{key} 必须是电脑上已存在的绝对目录")
        updates[key] = str(path.resolve())
    save_user_config(updates)
    for field, value in updates.items():
        setattr(config, field, value)
    reset_deps()
    return ok({"obsidian_root": config.obsidian_root,
               "recordings_root": str(config.resolved_recordings_root)})

_KINDS: tuple[str, ...] = ("transcription", "llm", "vision", "storage")


@router.get("/settings", summary="读取当前配置（脱敏）")
async def read_settings(config: AppConfig = Depends(get_config)) -> dict:
    """返回当前配置快照，密钥仅以布尔位呈现。"""
    return ok(from_app_config(config).model_dump())


@router.put("/settings", summary="更新系统配置（支持 Provider 与 Obsidian/教材路径，可选持久化）")
async def update_settings(
    payload: ProviderConfigUpdate,
    request: Request,
    config: AppConfig = Depends(get_config),
) -> dict:
    """更新配置项。默认持久化至 `config.user.yaml`。"""
    updates = payload.model_dump(exclude_none=True)
    persist = updates.pop("persist", True)

    if "obsidian_root" in updates:
        _require_local(request, config)

    for field, value in updates.items():
        setattr(config, field, value)

    # 若更新了 obsidian_root，则尝试确保目录可访问并具备基础骨架
    if "obsidian_root" in updates:
        obsidian_service = ObsidianService(config)
        try:
            obsidian_service.init_vault()
        except Exception:
            pass  # 宽松处理，由用户或客户端进一步校验

    # 持久化保存
    if persist and updates:
        save_user_config(updates)

    # 配置变化后重建依赖装配
    reset_deps()
    return ok(from_app_config(config).model_dump())


@router.get("/settings/obsidian", summary="读取当前 Obsidian 库状态与健康度")
async def get_obsidian_status(
    config: AppConfig = Depends(get_config),
) -> dict:
    """诊断当前生效的 Obsidian 目录是否存在、结构是否完整。"""
    service = ObsidianService(config)
    status = service.inspect_vault()
    return ok(status.model_dump())


@router.post("/settings/obsidian/validate", summary="校验指定路径是否为合规 Obsidian 库")
async def validate_obsidian_path(
    payload: ObsidianPathValidateRequest,
    config: AppConfig = Depends(get_config),
) -> dict:
    """供任意客户端（Windows / Android / Web）在用户选择路径后即时校验。"""
    raw_path = payload.path.strip().strip("'\"")
    if not raw_path:
        return ok(
            ObsidianPathStatusDTO(
                path="",
                exists=False,
                error="路径不能为空",
            ).model_dump()
        )
    service = ObsidianService(config)
    status = service.inspect_vault(Path(raw_path))
    return ok(status.model_dump())


@router.post("/settings/obsidian/init", summary="初始化指定目录为 Obsidian 课程库骨架并可选切换")
async def init_obsidian_vault(
    payload: ObsidianInitRequest,
    config: AppConfig = Depends(get_config),
) -> dict:
    """一键建立 `课堂笔记/`、`转写原文/`、`00-任务规划/已处理文件清单.md`。"""
    target_path_str = (payload.path or config.obsidian_root).strip().strip("'\"")
    if not target_path_str:
        raise ApiError(ErrorCode.VALIDATION_ERROR, "目标路径不能为空")

    target_path = Path(target_path_str)
    service = ObsidianService(config)

    try:
        created_dirs, initialized_files = service.init_vault(target_path)
    except Exception as exc:
        raise ApiError(ErrorCode.CONFIG_ERROR, f"初始化 Obsidian 目录失败：{exc}") from exc

    if payload.auto_switch:
        resolved_str = str(target_path.resolve())
        config.obsidian_root = resolved_str
        if payload.persist:
            save_user_config({"obsidian_root": resolved_str})
        reset_deps()

    status = service.inspect_vault(target_path)
    response = ObsidianInitResponse(
        path=str(target_path),
        created_dirs=created_dirs,
        initialized_files=initialized_files,
        status=status,
    )
    return ok(response.model_dump())


def _probe(kind: str, name: str, config: AppConfig) -> ProviderInfo:
    """尽力实例化 Provider 并读取能力；失败则标记为不可用。"""
    registry = get_registry()
    builder = {
        "transcription": registry.build_transcription,
        "llm": registry.build_llm,
        "vision": registry.build_vision,
        "storage": registry.build_storage,
    }[kind]
    try:
        provider: BaseProvider = builder(name)
        caps = provider.capabilities()
        return ProviderInfo(
            name=name,
            kind=kind,
            available=True,
            runs_offline=caps.runs_offline,
            incurs_cost=caps.incurs_cost,
            description=f"{provider.__class__.__name__}",
        )
    except Exception as exc:  # noqa: BLE001 - 不可用属正常状态，非错误
        return ProviderInfo(name=name, kind=kind, available=False, error=str(exc))


@router.get("/providers", summary="列出四类 Provider 可用列表 + capabilities")
async def list_providers(config: AppConfig = Depends(get_config)) -> dict:
    """列出四类 Provider 的可用性与能力描述。"""
    result: dict[str, Any] = {}
    for kind in _KINDS:
        names = ProviderRegistry.available(kind)
        result[kind] = [_probe(kind, name, config).model_dump() for name in names]
    result["active"] = {
        "transcription": config.transcription_provider,
        "llm": config.llm_provider,
        "vision": config.vision_provider,
        "storage": config.storage_backend,
    }
    return ok(result)
