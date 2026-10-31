"""Local-only ASR configuration. Independent of legacy provider selection."""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field

from app import config as app_config


class AsrSettings(BaseModel):
    model_config = ConfigDict(extra="forbid")
    enabled: bool = False
    mode: Literal["local_qwen", "local_whisper", "qwen_service"] = "local_qwen"
    managed_id: str = ""
    output_dir: str = ""
    python_path: str = ""
    model_path: str = ""
    aligner_path: str = ""
    ffmpeg_path: str = ""
    base_url: str = ""
    model: str = "Qwen3-ASR-1.7B"
    api_key: str = ""
    delete_source: bool = False
    min_chars: int = Field(default=1500, ge=1500)


def settings_path() -> Path:
    return app_config.USER_CONFIG_FILE.parent / "asr.user.json"


def load_settings() -> AsrSettings:
    path = settings_path()
    return AsrSettings.model_validate_json(path.read_text("utf-8")) if path.exists() else AsrSettings()


def public_settings(value: AsrSettings) -> dict:
    result = value.model_dump(exclude={"api_key"})
    result["api_key_set"] = bool(value.api_key)
    return result


def validate_settings(value: AsrSettings) -> None:
    if not value.output_dir or not Path(value.output_dir).is_absolute() or not Path(value.output_dir).is_dir():
        raise ValueError("转写保存目录必须是电脑上已存在的绝对目录")
    if value.mode in ("local_qwen", "local_whisper"):
        if value.managed_id:
            from app.services.asr_model_manager import get_model_manager
            receipt = get_model_manager().receipt(value.managed_id)
            expected_mode='local_qwen' if receipt['engine']=='qwen' else 'local_whisper'
            if value.mode!=expected_mode or not receipt.get('verified'):
                raise ValueError('模型类型不一致或尚未通过音频测试，请在模型页重新选择')
            for field in ('python_path','model_path','ffmpeg_path','aligner_path'):
                if getattr(value,field) != receipt.get(field,''):
                    raise ValueError('应用内模型的受管路径已变化，请在模型页重新选择')
        for field in (("python_path", "ffmpeg_path", "model_path", "aligner_path") if value.mode=='local_qwen' else ("python_path","ffmpeg_path","model_path")):
            p = Path(getattr(value, field))
            valid = p.is_file() if field.endswith("_path") and field in ("python_path", "ffmpeg_path") else p.is_dir()
            if not p.is_absolute() or not valid:
                raise ValueError(f"{field} 路径不存在或类型不正确")
    else:
        url = urlsplit(value.base_url)
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError("请填写 Qwen 服务的 HTTP(S) 基础地址，不要在地址中包含密钥")
        if not value.model.strip():
            raise ValueError("请填写服务提供的 Qwen 模型名")


def save_settings(value: AsrSettings) -> None:
    path = settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    with temp.open("w", encoding="utf-8") as f:
        json.dump(value.model_dump(), f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    temp.replace(path)


def detect_local() -> dict:
    """Offer explicit/user-owned runtimes only; do not scan another application's files."""
    import shutil

    home = Path(os.environ.get("REMEMBER_ASR_HOME", str(Path.home() / ".remember" / "asr"))).expanduser()
    python_candidates = [home / "venv" / "Scripts" / "python.exe", home / "venv" / "bin" / "python"]
    python = next((path for path in python_candidates if path.is_file()), None)
    models = home / "models"
    ffmpeg_name = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"
    local_ffmpeg = home / "bin" / ffmpeg_name
    ffmpeg = str(local_ffmpeg) if local_ffmpeg.is_file() else (shutil.which("ffmpeg") or "")
    result = {
        "python_path": str(python) if python else "",
        "model_path": str(models / "Qwen3-ASR-1.7B") if (models / "Qwen3-ASR-1.7B").is_dir() else "",
        "aligner_path": str(models / "Qwen3-ForcedAligner-0.6B") if (models / "Qwen3-ForcedAligner-0.6B").is_dir() else "",
        "ffmpeg_path": ffmpeg,
    }
    output = os.environ.get("REMEMBER_TRANSCRIPT_DIR", "").strip()
    if output and Path(output).expanduser().is_dir():
        result["output_dir"] = str(Path(output).expanduser())
    return result
