"""一键生成交接包（FR-16）。

用法（项目根或 server/ 下均可）：
    python scripts/generate_handoff.py --milestone M0 --stage 项目地基

说明：
    - 生成 ``docs/handoff/`` 下四份文件（AGENTS.md / PROJECT_STATE.md / handoff.json / ADR-*.md）。
    - ``conventions`` 由代码固定注入，不经 LLM。
    - LLM 未配置时自动降级为确定性总结（不报错）。
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

# 路径含中文，强制 UTF-8 输出
sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# 将 server/ 加入 sys.path，使 `app` 包可导入
_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_SERVER_DIR = _PROJECT_ROOT / "server"
if str(_SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(_SERVER_DIR))

from app.config import get_app_config  # noqa: E402
from app.logging_setup import get_logger, setup_logging  # noqa: E402
from app.services.handoff_service import HandoffService  # noqa: E402


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="生成 Remember 交接包（FR-16）")
    parser.add_argument("--milestone", default="M0", help="里程碑编号，如 M0 / M1")
    parser.add_argument("--stage", default=None, help="阶段名，如「项目地基」")
    parser.add_argument(
        "--no-llm", action="store_true", help="强制跳过 LLM，使用确定性总结"
    )
    return parser.parse_args()


async def _main() -> int:
    args = _parse_args()
    config = get_app_config()
    setup_logging(level=config.log_level, fmt="console")
    logger = get_logger("scripts.generate_handoff")

    llm = None
    if not args.no_llm:
        try:
            from app.deps import get_llm_provider

            llm = get_llm_provider()
        except Exception as exc:  # noqa: BLE001 - LLM 缺失不应阻断交接包
            logger.warning("llm_unavailable", error=str(exc))

    service = HandoffService(config, llm_provider=llm)
    result = await service.generate(milestone=args.milestone, stage=args.stage)

    print(f"[OK] 运行模式：{config.deployment_mode}")
    print(f"[OK] 交接包目录：{result['output_dir']}")
    print(f"[OK] 共写出 {len(result['files'])} 份文件：")
    for rel in result["files"]:
        print(f"     - {rel}")
    handoff = result["handoff"]
    print(f"[OK] conventions：{len(handoff['conventions'])} 条（代码固定注入）")
    print(f"[OK] environment_facts：{len(handoff['environment_facts'])} 条")
    print(f"[OK] 已完成任务：{handoff['stage_progress']['completed_tasks']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
