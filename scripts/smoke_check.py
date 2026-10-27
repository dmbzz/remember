"""M0 出口验收自验证脚本（可重复运行）。

覆盖 M0 出口验收 ①②③：
    ① ``python -m app.main`` 用**本地配置**与**云端配置**都能正常启动；
    ② ``GET /api/health`` 返回当前运行模式（local / cloud）；
    ③ ``POST /api/handoff/generate`` 生成 docs/handoff/ 下四份文件，且 handoff.json.conventions
       覆盖 PRD §0 的 9 条硬约束（逐项断言，不靠肉眼）。

用法：
    python scripts/smoke_check.py

说明：本地模式会真实写入 ``docs/handoff/``（这是交接包产物，属预期）；云端模式只验证
启动 + 鉴权（401），不覆写交接包，避免污染仓库。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SERVER_DIR = PROJECT_ROOT / "server"

# PRD §0 硬约束指纹（与 test_handoff_schema.py 保持一致）
PRD_FINGERPRINTS = ("融合式", "◉", "回填", "老师路线", "faster-whisper", "Obsidian", "无日期前缀", "删除", "ROCm")
# v3.1 关键决策指纹（同步方向 / 批注链路 / 同步范围 / 同步口径 / 离线边界 / 隐私 / 版权 / 原生录音）
NEW_FINGERPRINTS = ("三处并存", "单向下行", "批注", "保留两份", "按需拉取", "同步口径", "离线边界", "上云", "版权", "Kotlin")
# 已废止，不得残留（v3.0 推翻的旧规则 + v3.1 废弃的泛化表述）
OVERTURNED_FINGERPRINTS = ("单一数据源", "不存副本", "只索引不存正文", "双向同步")


def _python() -> str:
    candidates = [
        os.environ.get("CNA_PYTHON", ""),
        str(SERVER_DIR / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    return sys.executable


def _start_server(config_file: str, port: int) -> tuple[subprocess.Popen, Path]:
    """启动后端子进程，日志写入临时文件（便于失败排查）。"""
    log_path = Path(tempfile.gettempdir()) / f"cna_smoke_{port}.log"
    env = dict(os.environ)
    env["CNA_CONFIG_FILE"] = config_file
    env["CNA_HOST"] = "127.0.0.1"
    env["CNA_PORT"] = str(port)
    env["CNA_LOG_FORMAT"] = "console"
    handle = log_path.open("w", encoding="utf-8")
    process = subprocess.Popen(  # noqa: S603
        [_python(), "-m", "app.main"],
        cwd=str(SERVER_DIR),
        env=env,
        stdout=handle,
        stderr=subprocess.STDOUT,
    )
    return process, log_path


def _wait_health(port: int, timeout: float = 60.0) -> dict:
    """轮询 /api/health 直到就绪。"""
    deadline = time.time() + timeout
    last_error = ""
    while time.time() < deadline:
        try:
            response = httpx.get(f"http://127.0.0.1:{port}/api/health", timeout=3.0)
            if response.status_code == 200:
                return response.json()
        except Exception as exc:  # noqa: BLE001 - 启动期连接失败属正常
            last_error = str(exc)
        time.sleep(0.5)
    raise RuntimeError(f"服务未在 {timeout}s 内就绪（最后错误：{last_error}）")


def _stop(process: subprocess.Popen, log_path: Path) -> str:
    process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
    return log_path.read_text(encoding="utf-8", errors="ignore")


def _check_handoff(payload: dict) -> None:
    """断言交接包四份文件齐备 + conventions 覆盖硬约束。"""
    out_dir = Path(payload["output_dir"])
    required = ["AGENTS.md", "PROJECT_STATE.md", "handoff.json"]
    for name in required:
        assert (out_dir / name).is_file(), f"缺少文件：{name}"
    adrs = sorted((out_dir / "decisions").glob("ADR-*.md"))
    assert len(adrs) == 7, f"ADR 数量应为 7（含 v3.3 ADR-007），实际 {len(adrs)}"
    print(f"   [③] 四份文件齐备：{required} + decisions/ADR-*.md × {len(adrs)}")

    raw = json.loads((out_dir / "handoff.json").read_text(encoding="utf-8"))
    conventions = raw["conventions"]
    assert len(conventions) >= 11, f"conventions 应 ≥11 条，实际 {len(conventions)}"
    joined = "\n".join(conventions) + "\n" + "\n".join(raw["environment_facts"])
    for fingerprint in PRD_FINGERPRINTS:
        assert fingerprint in joined, f"PRD 硬约束指纹缺失：{fingerprint}"
    conventions_joined = "\n".join(conventions)
    for fingerprint in NEW_FINGERPRINTS:
        assert fingerprint in conventions_joined, f"新增决策指纹缺失：{fingerprint}"
    for stale in OVERTURNED_FINGERPRINTS:
        assert stale not in conventions_joined, f"已推翻的旧规则残留：{stale}"
    print(
        f"   [③] conventions={len(conventions)} 条（代码固定注入），"
        f"environment_facts={len(raw['environment_facts'])} 条；"
        f"PRD 9 条硬约束 + v3.1 决策指纹全部命中，已废止表述（单一数据源/双向同步）无残留 ✓"
    )
    print(f"   [③] 已完成任务数：{raw['stage_progress']['completed_tasks']}")


def main() -> int:
    print("=" * 78)
    print("M0 出口验收自验证（smoke_check）")
    print("=" * 78)
    print(f"Python：{_python()}")

    # ---- ① 本地模式 ----
    print("\n[1/2] 本地模式（config/config.local.yaml）")
    process, log_path = _start_server("config/config.local.yaml", 8123)
    try:
        health = _wait_health(8123)
        print(f"   [①] 启动成功 ✓")
        print(f"   [②] GET /api/health → {json.dumps(health, ensure_ascii=False)}")
        assert health["data"]["mode"] == "local", "本地模式 mode 应为 local"

        response = httpx.post(
            "http://127.0.0.1:8123/api/handoff/generate",
            json={"milestone": "M0", "stage": "项目地基"},
            timeout=60.0,
        )
        response.raise_for_status()
        body = response.json()
        assert body["code"] == 0, f"生成交接包失败：{body}"
        _check_handoff(body["data"])
    finally:
        logs = _stop(process, log_path)
    if "app_starting" not in logs and "Uvicorn running" not in logs:
        print("   （启动日志片段）\n" + "\n".join(logs.splitlines()[:15]))

    # ---- ② 云端模式 ----
    print("\n[2/2] 云端模式（config/config.cloud.yaml）")
    process, log_path = _start_server("config/config.cloud.yaml", 8124)
    try:
        health = _wait_health(8124)
        print(f"   [①] 启动成功 ✓")
        print(f"   [②] GET /api/health → {json.dumps(health, ensure_ascii=False)}")
        assert health["data"]["mode"] == "cloud", "云端模式 mode 应为 cloud"

        unauth = httpx.post(
            "http://127.0.0.1:8124/api/handoff/generate",
            json={"milestone": "M0"},
            timeout=10.0,
        )
        print(f"   [FR-18] 无 Token 调用受保护接口 → HTTP {unauth.status_code}（期望 401）")
        assert unauth.status_code == 401, "云端模式未鉴权应返回 401"
    finally:
        logs = _stop(process, log_path)
    if "Uvicorn running" not in logs:
        print("   （启动日志片段）\n" + "\n".join(logs.splitlines()[:15]))

    print("\n" + "=" * 78)
    print("全部验收通过 ✓")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
