"""Per-PC opt-in notifications, independent from ASR credentials and model settings."""
import json
import logging
import os
from pathlib import Path
import subprocess

from pydantic import BaseModel, ConfigDict
from app import config
from app.services.atomic_files import atomic_json

log = logging.getLogger(__name__)

class DesktopSettings(BaseModel):
    model_config = ConfigDict(extra="forbid")
    asr_notifications: bool = False

def load_desktop_settings():
    path = config.USER_CONFIG_FILE.parent / "desktop.user.json"
    return DesktopSettings.model_validate_json(path.read_text("utf-8")) if path.exists() else DesktopSettings()

def save_desktop_settings(value):
    config.USER_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    atomic_json(config.USER_CONFIG_FILE.parent / "desktop.user.json", value.model_dump())

def notify_asr(event, source):
    # Called only at lifecycle boundaries, never on a progress poll.
    try:
        if os.name != "nt" or not load_desktop_settings().asr_notifications:
            return
        if config.get_app_config().deployment_mode != "local":
            return
        server = Path(__file__).resolve().parents[2]
        executable = server.parent.parent / "app.exe"
        if server.parent.name != "backend" or not executable.is_file():
            log.warning("ASR notification unavailable: desktop executable missing")
            return
        titles = {"started": "开始转写课堂录音", "completed": "课堂录音转写完成",
                  "incomplete": "课堂录音转写不完整", "failed": "课堂录音转写失败"}
        message = f"{source}。" + ("结果已保存到转写文件夹。" if event == "completed" else
                   "源录音保留，可在应用中查看并重试。" if event in ("failed", "incomplete") else
                   "可在应用中查看实时进度。")
        result = subprocess.run([str(executable), "--asr-notification", titles[event], message],
                                capture_output=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode:
            log.warning("ASR notification not delivered: code=%s (2=disabled by Windows)", result.returncode)
    except Exception:
        log.warning("ASR notification unavailable", exc_info=True)
