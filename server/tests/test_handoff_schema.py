"""交接包 schema 冒烟测试：``handoff.json`` 必含 ``conventions`` 与 ``environment_facts``，四份文件齐备。

**关键断言**（对应 M0 出口验收 ③）：``handoff.json.conventions`` 必须覆盖
PRD §0 的 9 条硬约束 + 关键决策（v3.0：笔记多端同步、同步范围、离线边界、隐私范围、版权边界、
安卓原生录音桥接），且其内容与代码常量 **逐条一致**（证明是固定注入，而非 LLM 生成）。

**v3.0 变更**：原「Obsidian 单一数据源（App 不存副本）」已被推翻，指纹相应改为
「三处并存 / 保留两份」及「按需拉取 / 离线边界」。
**v3.1 变更**：同步**方向**细化——正文 `Win↔云端` 双向、`云端→Android` 单向下行（只读）；
批注 `Android→云端→Win` 单向上行；新增「同步口径」；泛化的「双向同步」表述已废弃。
**v3.3 变更**：新增 ADR-007（笔记第 10 节改为「学习建议」，不生成自测题），以 ``refines``
**部分精化** ADR-001（非 ``supersedes``）；ADR 数量 6 → 7。
"""

from __future__ import annotations

import json
from pathlib import Path

from app.config import get_app_config
from app.services.handoff_service import (
    ENVIRONMENT_FACTS,
    FIXED_CONVENTIONS,
    HandoffService,
)

# PRD §0「必须继承的既有规则与资产」9 条硬约束的关键词指纹
PRD_HARD_CONSTRAINTS_FINGERPRINTS: tuple[str, ...] = (
    "融合式",          # 1. 融合式单文件笔记 + mindmap + callout
    "◉",               # 2. 出处标记 ◉课件 / ◉教材
    "回填",            # 3. 教材回填
    "老师路线",        # 4. 作业辅导老师路线优先
    "faster-whisper",  # 5. 转写链路 ROCm + faster-whisper-medium
    "Obsidian",        # 6. 数据资产（Obsidian 库 / 教材原件）
    "无日期前缀",      # 7. 归档与命名规则
    "删除",            # 8. 音频转写成功后删除
    "ROCm",            # 9. 环境事实（AMD ROCm）
)

# v3.1 关键决策的关键词指纹（同步方向 / 批注链路 / 同步范围 / 同步口径 / 离线边界 / 隐私 / 版权 / 原生录音）
NEW_DECISION_FINGERPRINTS: tuple[str, ...] = (
    "三处并存",     # FR-31 三处并存（Obsidian / 云端 / Android）
    "单向下行",     # FR-31 同步方向：云端→Android 单向下行（手机只读正文）
    "批注",         # FR-31 批注 Android→云端→Win 单向上行（独立存储、不覆盖原文）
    "保留两份",     # FR-31 冲突 keep-both，绝不静默覆盖
    "按需拉取",     # FR-31 同步范围只含笔记 Markdown
    "同步口径",     # v3.1 延迟但不丢数据，不承诺后台实时同步
    "离线边界",     # FR-32 离线能力边界
    "上云",         # 隐私范围（允许上云）
    "版权",         # 版权边界（扫描原图不进入导出）
    "Kotlin",       # 安卓原生录音桥接
)


async def _generate() -> tuple[dict, Path]:
    """执行交接包生成，返回 (handoff 字典, 输出目录)。输出目录由夹具注入到临时路径。"""
    config = get_app_config()
    service = HandoffService(config, llm_provider=None)  # 强制无 LLM → 确定性路径
    result = await service.generate(milestone="M0", stage="项目地基")
    return result["handoff"], Path(result["output_dir"])


async def test_four_handoff_files_exist() -> None:
    """四类文件齐备：AGENTS.md / PROJECT_STATE.md / handoff.json / decisions/ADR-*.md。"""
    _, out = await _generate()
    assert (out / "AGENTS.md").is_file()
    assert (out / "PROJECT_STATE.md").is_file()
    assert (out / "handoff.json").is_file()
    decisions = out / "decisions"
    assert decisions.is_dir()
    assert len(sorted(decisions.glob("ADR-*.md"))) == 7  # v3.3：ADR-001~005 + ADR-006 + ADR-007


async def test_handoff_json_required_keys() -> None:
    """handoff.json 含 schema 要求的全部关键字段。"""
    _, out = await _generate()
    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    for key in (
        "$schema",
        "project",
        "schema_version",
        "generated_at",
        "milestone",
        "stage",
        "stage_progress",
        "summary",
        "done",
        "in_progress",
        "todo",
        "blocked",
        "conventions",
        "decisions",
        "key_paths",
        "environment_facts",
    ):
        assert key in raw, f"handoff.json 缺少字段：{key}"
    assert raw["project"] == "class_notes_assistant"
    assert raw["milestone"] == "M0"


async def test_conventions_injected_by_code() -> None:
    """conventions 由代码固定注入：≥11 条，且与常量逐条一致。"""
    data, out = await _generate()
    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    conventions = raw["conventions"]
    assert isinstance(conventions, list)
    assert len(conventions) >= 11
    assert conventions == list(FIXED_CONVENTIONS)
    assert data["conventions"] == list(FIXED_CONVENTIONS)


async def test_conventions_cover_prd_hard_constraints() -> None:
    """conventions + environment_facts 覆盖 PRD §0 的 9 条硬约束。"""
    _, out = await _generate()
    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    joined = "\n".join(raw["conventions"]) + "\n" + "\n".join(raw["environment_facts"])
    for fingerprint in PRD_HARD_CONSTRAINTS_FINGERPRINTS:
        assert fingerprint in joined, f"硬约束指纹缺失：{fingerprint}"


async def test_conventions_cover_new_decisions() -> None:
    """conventions 覆盖 v3.1 关键决策（三处并存/单向下行/批注/保留两份/同步范围/同步口径/离线边界/隐私/版权/原生录音）。"""
    _, out = await _generate()
    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    joined = "\n".join(raw["conventions"])
    for fingerprint in NEW_DECISION_FINGERPRINTS:
        assert fingerprint in joined, f"新增决策指纹缺失：{fingerprint}"


async def test_overturned_rule_removed() -> None:
    """v3.0 已推翻的「Obsidian 单一数据源 / App 不存副本」**不得**在 conventions 中残留。"""
    _, out = await _generate()
    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    joined = "\n".join(raw["conventions"])
    for stale in ("单一数据源", "不存副本", "只索引不存正文"):
        assert stale not in joined, f"旧规则残留（应已删除）：{stale}"


async def test_sync_direction_specified_not_generic() -> None:
    """v3.1：同步方向必须方向化（正文 Win↔云端双向 / 云端→Android 单向下行），不得再用泛化「双向同步」。"""
    _, out = await _generate()
    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    joined = "\n".join(raw["conventions"])
    assert "双向同步" not in joined, "残留泛化表述「双向同步」，应为方向化描述"
    assert "单向下行" in joined
    assert "批注" in joined


async def test_environment_facts_present() -> None:
    """environment_facts 由代码注入且非空。"""
    _, out = await _generate()
    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    assert raw["environment_facts"] == list(ENVIRONMENT_FACTS)
    assert len(raw["environment_facts"]) >= 4


async def test_agents_md_contains_conventions_section() -> None:
    """AGENTS.md 含硬约定清单小节（供接手模型直接阅读）。"""
    _, out = await _generate()
    content = (out / "AGENTS.md").read_text(encoding="utf-8")
    assert "硬约定清单" in content
    assert "◉" in content


async def test_agents_md_no_stale_wording_or_typo() -> None:
    """AGENTS.md 不得含旧「真相源」表述与 `fluter` 拼写错误；数据路径口径为「数据资产根」。

    防回归：§2 技术栈若再写「数据真相源」会与 §4 硬约定（三处并存）自相矛盾。
    """
    _, out = await _generate()
    content = (out / "AGENTS.md").read_text(encoding="utf-8")
    assert "真相源" not in content, "AGENTS.md 残留旧「真相源」表述（与三处并存矛盾）"
    assert "fluter" not in content, "AGENTS.md 存在 fluter 拼写错误"
    assert "双向同步" not in content, "AGENTS.md 残留泛化表述「双向同步」，应为方向化描述"
    assert "数据资产根" in content
    assert "三处并存" in content

    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    assert "flutter_entry" in raw["key_paths"], "key_paths 键名应为 flutter_entry"
    assert "fluter_entry" not in raw["key_paths"]
    # 环境事实统一到 venv 路径（依赖装于此）
    env_joined = "\n".join(raw["environment_facts"])
    assert "server/.venv/Scripts/python.exe" in env_joined


async def test_adr_files_are_append_only() -> None:
    """ADR 只增不改：再次生成不覆写既有 ADR 内容（无 revision 的 ADR 为 write-once）。"""
    _, out = await _generate()
    adr_file = sorted((out / "decisions").glob("ADR-*.md"))[0]
    original = adr_file.read_text(encoding="utf-8")
    # 模拟人工修订后再次生成
    adr_file.write_text(original + "\n<!-- 人工补充 -->\n", encoding="utf-8")
    await _generate()
    assert "人工补充" in adr_file.read_text(encoding="utf-8")


async def test_adr006_reflects_v31_revision() -> None:
    """ADR-006 反映 v3.1「表述精确化」修订：含「修订记录」+ 方向化描述，且保留 supersedes Q-11。"""
    _, out = await _generate()
    content = (out / "decisions" / "ADR-006-笔记多端同步.md").read_text(encoding="utf-8")
    assert "修订记录" in content
    assert "同步方向细化" in content
    assert "单向下行" in content
    assert "Q-11" in content  # supersedes 行保持不动


async def test_adr006_absorbs_detailed_sections() -> None:
    """ADR-006 常量已吸收详细版三节：技术落点 / 被否方案 / 后果（生成版信息量 ≥ 手写版）。

    且**可选小节按有无输出**：无这些字段的 ADR（如 ADR-001）不应出现空小节。
    """
    _, out = await _generate()
    decisions = out / "decisions"

    content = (decisions / "ADR-006-笔记多端同步.md").read_text(encoding="utf-8")
    for heading in ("## 技术落点", "## 被否方案（Alternatives Considered）", "## 后果（Consequences）"):
        assert heading in content, f"ADR-006 缺少小节：{heading}"
    # note_id 关联取舍（被否：用文件路径关联）
    assert "note_id" in content and "文件路径" in content
    # 后果须含代价（含负面）
    assert "手机不能编辑正文" in content
    # 生成版应比手写详细版更完整：含全部小节 + 修订记录 + supersedes 注记
    assert "修订记录" in content and "supersedes: ADR-006" in content

    # 背景节须含「决策源头证据」：用户原话 + 原前提三处不足
    assert "安卓端没有 win 支持" in content  # 用户原话
    assert "安卓手机里的笔记内容" in content  # 用户原话
    assert "无法离线读笔记" in content  # 不足②
    assert "而非单点权威" in content  # 不足③
    assert "若只有索引没有正文，链路断裂" in content  # 不足①（只有索引为何不够）

    # ADR-001 无可选小节字段 → 不应渲染出空小节
    adr1 = (decisions / "ADR-001-融合式单文件笔记格式.md").read_text(encoding="utf-8")
    for heading in ("## 技术落点", "## 被否方案", "## 后果"):
        assert heading not in adr1, f"ADR-001 不应含小节：{heading}"


async def test_adr007_refines_not_supersedes_adr001() -> None:
    """ADR-007（第 10 节改为「学习建议」）以 ``refines`` **部分精化** ADR-001，而非 ``supersedes`` 取代。

    回归断言（对应 ADR-007 收尾清单第 4 项）：
      - ``refines`` 行存在且指向 ``ADR-001``（渲染于 supersedes 行之后）；
      - **不出现** ``supersedes`` 行——本 ADR 未推翻 ADR-001（其余格式仍有效，仅第 10 节内涵收窄）。
    """
    _, out = await _generate()
    decisions = out / "decisions"
    adr7_file = decisions / "ADR-007-笔记不生成自测题.md"
    assert adr7_file.is_file(), "缺少 ADR-007 文件"

    content = adr7_file.read_text(encoding="utf-8")

    # refines 行存在且指向 ADR-001
    assert "部分精化（refines）**：ADR-001" in content
    # 不得出现 supersedes 行 —— 部分精化 ≠ 取代
    assert "取代（supersedes）" not in content, "ADR-007 不应含 supersedes 行（应为 refines）"

    # 五个正文小节齐备（背景 / 决策 / 理由 / 被否方案 / 后果）
    for heading in (
        "## 背景（Context）",
        "## 决策（Decision）",
        "## 理由（Rationale）",
        "## 被否方案（Alternatives Considered）",
        "## 后果（Consequences）",
    ):
        assert heading in content, f"ADR-007 缺少小节：{heading}"

    # 核心口径：不生成自测题，第 10 节只保留学习建议
    assert "不生成自测题" in content
    assert "学习建议" in content

    # handoff.json 的 decisions 清单亦须登记 ADR-007
    raw = json.loads((out / "handoff.json").read_text(encoding="utf-8"))
    adr_ids = [d["id"] for d in raw["decisions"]]
    assert "ADR-007" in adr_ids, f"handoff.json decisions 缺少 ADR-007：{adr_ids}"
    assert len(adr_ids) == 7, f"ADR 决策数应为 7，实际 {len(adr_ids)}"


async def test_project_state_overwritten_each_run() -> None:
    """PROJECT_STATE.md 每次生成整体覆盖，且含五类任务小节。"""
    _, out = await _generate()
    content = (out / "PROJECT_STATE.md").read_text(encoding="utf-8")
    for section in ("已完成", "进行中", "待办", "阻塞", "硬约定"):
        assert section in content


def test_scan_codebase_finds_modules() -> None:
    """代码库扫描能发现后端模块。"""
    files = HandoffService.scan_codebase()
    assert files, "代码库扫描结果不应为空"
    joined = "\n".join(files)
    assert "server/app/providers/base.py" in joined
    assert "server/app/services/handoff_service.py" in joined
