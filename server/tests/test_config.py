"""配置系统冒烟测试：本地/云端切换 + 环境变量覆盖 YAML。

对应架构设计附录 A：``CNA_DEPLOYMENT_MODE`` 切换导致 db_url / provider 选择变化；env 覆盖 YAML。
"""

from __future__ import annotations

from pathlib import Path

import pytest

from app.config import CONFIG_DIR, get_app_config, reset_app_config


def _load(monkeypatch: pytest.MonkeyPatch, **env: str):
    """按给定环境变量重新加载配置。"""
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    reset_app_config()
    return get_app_config()


def test_local_mode_defaults() -> None:
    """默认（本地）模式：SQLite + 本地文件 + local_gpu。"""
    config = get_app_config()
    assert config.deployment_mode == "local"
    assert config.is_cloud is False
    assert config.is_sqlite is True
    assert config.db_url.startswith("sqlite+aiosqlite")
    assert config.storage_backend == "local_fs"
    assert config.transcription_provider == "local_gpu"
    assert config.auth_enabled is False


def test_cloud_mode_via_config_file(monkeypatch: pytest.MonkeyPatch) -> None:
    """切换配置文件 → 云端形态（Postgres + 对象存储 + cloud_api + 强制鉴权）。"""
    config = _load(
        monkeypatch, CNA_CONFIG_FILE=str(CONFIG_DIR / "config.cloud.yaml")
    )
    assert config.deployment_mode == "cloud"
    assert config.is_cloud is True
    assert config.is_sqlite is False
    assert config.db_url.startswith("postgresql+asyncpg")
    assert config.storage_backend == "object_store"
    assert config.transcription_provider == "cloud_api"
    assert config.auth_enabled is True
    assert config.force_https is True


def test_env_switches_deployment_mode(monkeypatch: pytest.MonkeyPatch) -> None:
    """``CNA_DEPLOYMENT_MODE=cloud`` 自动匹配 config.cloud.yaml。"""
    monkeypatch.delenv("CNA_CONFIG_FILE", raising=False)
    config = _load(monkeypatch, CNA_DEPLOYMENT_MODE="cloud")
    assert config.deployment_mode == "cloud"
    assert config.db_url.startswith("postgresql+asyncpg")


def test_env_overrides_yaml(monkeypatch: pytest.MonkeyPatch) -> None:
    """环境变量（CNA_ 前缀）优先级高于 YAML。"""
    override_db = "sqlite+aiosqlite:///C:/tmp/override.db"
    config = _load(
        monkeypatch,
        CNA_DB_URL=override_db,
        CNA_TRANSCRIPTION_PROVIDER="cloud_api",
        CNA_AUTH_ENABLED="true",
    )
    assert config.db_url == override_db
    assert config.transcription_provider == "cloud_api"
    assert config.auth_enabled is True


def test_provider_settings_are_typed() -> None:
    """Provider 参数段可被类型化读取。"""
    config = get_app_config()
    local_gpu = config.provider_settings("local_gpu")
    assert local_gpu.get("model_name") == "faster-whisper-medium"
    assert str(local_gpu.get("device")) == "cpu"  # Portable sample; GPU is an explicit device choice.
    # cloud_api 对外名映射到 providers.cloud_asr 段
    cloud_asr = config.provider_settings("cloud_api")
    assert "model" in cloud_asr


def test_resolved_handoff_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """交接包目录解析：相对路径基于项目根，绝对路径原样使用。"""
    target = tmp_path / "handoff"
    config = _load(monkeypatch, CNA_HANDOFF_DIR=str(target))
    assert config.resolved_handoff_dir == target


def test_sync_config_v3() -> None:
    """v3.0 同步配置段（FR-31/FR-32）：范围只含笔记 Markdown、冲突保留两份。"""
    config = get_app_config()
    assert config.sync.enabled is True
    assert config.sync.scope == "notes_markdown"
    assert config.sync.conflict_policy == "keep_both"
    assert config.sync.interval_seconds == 300


def test_sync_config_cloud_mode(monkeypatch: pytest.MonkeyPatch) -> None:
    """云端模式也带 sync 段（云端为同步汇聚点）。"""
    config = _load(monkeypatch, CNA_CONFIG_FILE=str(CONFIG_DIR / "config.cloud.yaml"))
    assert config.sync.enabled is True
    assert config.sync.conflict_policy == "keep_both"
