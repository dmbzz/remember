"""pytest 公共夹具：隔离配置与数据库，避免污染真实数据目录。

约定：
    - 将 ``server/`` 加入 ``sys.path``，使 ``app`` 包可导入。
    - 每个测试前把 ``CNA_DB_URL`` / ``CNA_HANDOFF_DIR`` 指向临时目录。
    - 测试后清空 config / registry / database 单例缓存（防止串味）。
"""

from __future__ import annotations

import sys
from collections.abc import Iterator
from pathlib import Path

import pytest

SERVER_DIR = Path(__file__).resolve().parent.parent
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from app.config import CONFIG_DIR, PROJECT_ROOT, reset_app_config  # noqa: E402
from app.db.session import reset_database  # noqa: E402
from app.deps import reset_deps  # noqa: E402


@pytest.fixture(autouse=True)
def _isolate_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """自动隔离：临时交接包目录 + 清空单例缓存。

    注意：**不覆盖** ``CNA_DB_URL``——否则会盖掉云端 YAML 的 Postgres 连接串，
    导致 ``test_config`` 无法验证形态切换。M0 冒烟测试不真正打开数据库连接。
    """
    monkeypatch.setenv("CNA_CONFIG_FILE", str(CONFIG_DIR / "config.local.yaml"))
    monkeypatch.setenv("CNA_HANDOFF_DIR", str(tmp_path / "handoff"))
    monkeypatch.delenv("CNA_DEPLOYMENT_MODE", raising=False)
    reset_app_config()
    reset_deps()
    reset_database()
    try:
        yield
    finally:
        reset_app_config()
        reset_deps()
        reset_database()


@pytest.fixture
def project_root() -> Path:
    """项目根目录。"""
    return PROJECT_ROOT


@pytest.fixture
def config_dir() -> Path:
    """配置文件目录。"""
    return CONFIG_DIR
