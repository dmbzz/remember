"""交接包生成器（FR-16）—— 生成 docs/handoff/ 下四份文件。

产出：
    - ``AGENTS.md``        入口：项目是什么 / 技术栈 / 怎么跑 / **硬约定清单**
    - ``PROJECT_STATE.md`` 人读：阶段 / 已完成 / 进行中 / 待办 / 阻塞
    - ``handoff.json``     机读：结构化状态（schema 见架构设计 §7.5）
    - ``decisions/ADR-*.md`` 决策记录（默认 **只增不改**；**表述精确化**例外，见 ADR 文末「修订记录」）

核心设计（不可动摇）：
    ``conventions`` 与 ``environment_facts`` 由 **代码常量固定注入**，
    **绝对不由 LLM 生成**——这是防「换了个模型后把用户拍板过的规则全推翻」的保险。
    LLM 仅负责 ``summary`` 与阶段总结，且失败时降级为确定性文本。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pydantic import BaseModel

from app.config import CONFIG_DIR, PROJECT_ROOT, AppConfig
from app.errors import ProviderError
from app.logging_setup import get_logger
from app.providers.base import LLMMessage, LLMProvider
from app.schemas.handoff import HandoffJson, StageProgress, TaskRef

__all__ = [
    "HandoffService",
    "FIXED_CONVENTIONS",
    "ENVIRONMENT_FACTS",
    "ADR_DEFS",
    "TASK_DEFS",
    "MILESTONE_STAGES",
]

_log = get_logger("app.services.handoff")

# ===========================================================================
# 固定注入常量（禁止由 LLM 生成）
# ===========================================================================

# 覆盖 PRD §0 的 9 条硬约束 + 关键决策，且**逐条对齐 PRD v3.1 §3.1 的 conventions 措辞**。
#
# 对齐说明（v3.1）：
#   - 凡 PRD §3.1 已列出的条目，措辞**以其为准**（含 §3.1 新增的「同步口径」；方向化后的三处并存条目）。
#   - PRD §3.1 的示例为**节选**，未列出但 §0 明确要求者，**保留**为独立条目：
#     ① callout（§0#1）、② 归档路径（§0#7）、③ 本地转写链路 ROCm+faster-whisper（§0#5）、
#     ④ 部署形态同码切换（§0 项目信息）。
#   - 历史沿革：v3.0 曾删除被推翻的「Obsidian 单一数据源（App 不存副本）」；v3.1 将同步**方向**细化
#     （正文 Win↔云端双向 / 云端→Android 单向下行只读；批注 Android→云端→Win 单向上行）。
# 本常量是**当前有效规则集**：被推翻的规则必须删除，描述不精确的必须对齐（不再传播旧/模糊事实）。
FIXED_CONVENTIONS: tuple[str, ...] = (
    "笔记为融合式单文件，结构固定不可裁剪：frontmatter→概述→Mermaid mindmap→核心知识点→"
    "老师强调→事务待办→勘误表→⚠️待确认→学习建议；第 10 节只提供学习建议，"
    "不生成自测题/练习题/折叠答案（见 ADR-001、ADR-007）",
    "每个知识点末尾必须有 `> [!tip] 💡 拓展｜<标题>` callout（为什么/怎么用/陷阱）",
    "出处标记：◉课件 / ◉教材，可追溯",
    "笔记命名：简洁关键词，无日期前缀、无后缀，日期放文件名末尾",
    "归档路径：笔记→课堂笔记\\<课程名>\\<主题>_YYYY-MM-DD.md；"
    "转写原文→转写原文\\<课程名>_第N次课_YYYY-MM-DD.txt；"
    "登记→00-任务规划\\已处理文件清单.md",
    "笔记三处并存（Obsidian / 云端 / Android 本地）：正文 Win↔云端 双向、"
    "云端→Android 单向下行（只读，手机不改正文）；批注 Android→云端→Win 单向上行；"
    "冲突保留两份，绝不静默覆盖",
    "同步口径：延迟但不丢数据，不承诺后台实时同步",
    "同步范围只含笔记 Markdown；转写原文与教材扫描图不预同步，按需拉取",
    "音频转写验证成功后删除，仅保留转写原文",
    "作业辅导：老师路线优先，AI 独立解仅作校验，禁止两种都对",
    "教材回填只填教材确有内容，否则保留 ⚠️待确认",
    "隐私范围：课堂录音与教材扫描件均允许上云处理（个人学习用途）",
    "版权边界：教材与课件的扫描原图不进入任何导出/分享产物",
    "离线边界：无服务器时只读本地笔记与检索，AI 解题需联网；不做手机端本地大模型推理",
    "安卓录音走 Kotlin 原生桥接，不用三方录音插件",
    "legacy 转写 Provider 使用可配置的 faster-whisper-medium；ROCm/CUDA 与计算精度按实际运行环境选择",
    "部署形态同一套代码配置切换（local/cloud）；不做教务系统爬取",
    "归档库：./data/notes\\",
)

ENVIRONMENT_FACTS: tuple[str, ...] = (
    "Windows/Android 客户端；开发使用项目自备的 Flutter 与 Python 工具链",
    "Python 使用 server/.venv/Scripts/python.exe（Windows）或 server/.venv/bin/python（POSIX）",
    "脚本按 UTF-8 读写文本与中文路径",
    "GPU 运行时按设备配置；ROCm/CUDA 依赖需自行安装，未配置时使用可用的 CPU 或服务模式",
)

# ADR 决策记录（默认**只增不改**）：初始五篇对应 PRD §8.1；v3.0 新增 ADR-006（FR-31/FR-32，取代 Q-11）；
# v3.3 新增 ADR-007（笔记第 10 节改为「学习建议」，**部分精化** ADR-001，非取代）。
#
# 修订判据（区分「决策变更」与「表述精确化」）：
#   - **决策变更**（原来决定 A，现改决定 B）→ **新建** ADR-NNN 并标注 `supersedes`，旧的原文一字不改。
#   - **表述精确化**（决策未变，只是描述不够准确）→ **修订原 ADR**，并在文末追加「修订记录」。
#     （带 ``revision`` 字段的 ADR 允许刷新落盘，以便把修订内容写进文件；见 ADR-006。）
ADR_DEFS: tuple[dict[str, str], ...] = (
    {
        "id": "ADR-001",
        "title": "融合式单文件笔记格式",
        "filename": "ADR-001-融合式单文件笔记格式.md",
        "date": "2026-09-16",
        "scope": "笔记生成 / 模板",
        "context": (
            "课堂笔记原先分散在概述、知识点、考点、待办等多个片段，复习时需在多个文件间跳转，"
            "且不同模型重新生成时容易裁掉 mindmap 或 callout，导致规则漂移。"
        ),
        "decision": (
            "笔记采用**融合式单文件**：固定小节顺序为 frontmatter→概述(3-5 句)→Mermaid mindmap→"
            "核心知识点→老师强调→事务待办→勘误表→⚠️待确认→学习建议与自测；"
            "每个知识点末尾附 `> [!tip] 💡 拓展｜<标题>` callout（为什么/怎么用/陷阱）。"
        ),
        "rationale": "复习场景需要一份文件看全；固定结构可被代码确定性渲染，避免模型裁剪规则。",
    },
    {
        "id": "ADR-002",
        "title": "笔记文件命名规则",
        "filename": "ADR-002-笔记文件命名规则.md",
        "date": "2026-09-16",
        "scope": "归档 / 命名",
        "context": "既有笔记命名不统一，有的带日期前缀、有的带后缀，排序与检索混乱。",
        "decision": (
            "笔记文件名统一为 `<主题>_YYYY-MM-DD.md`：3-6 字简洁关键词、**无日期前缀、无后缀**、"
            "日期放文件名**末尾**；转写原文为 `<课程名>_第N次课_YYYY-MM-DD.txt`（不可改）。"
        ),
        "rationale": "末尾日期保证按主题聚类、按时间排序；去除前后缀避免冗余与检索干扰。",
    },
    {
        "id": "ADR-003",
        "title": "转写后删除音频",
        "filename": "ADR-003-转写后删除音频.md",
        "date": "2026-09-16",
        "scope": "录音 / 存储",
        "context": "90 分钟课程音频约 80-100MB，长期累积占用大量空间且涉及隐私。",
        "decision": (
            "转写并验证成功后**删除音频**，仅保留转写原文；``Recording.file_path`` 置空并记 "
            "``deleted_at``。"
        ),
        "rationale": "转写原文已满足复习与检索需求；删除音频降低存储与隐私风险。",
    },
    {
        "id": "ADR-004",
        "title": "作业辅导老师路线优先",
        "filename": "ADR-004-作业辅导老师路线优先.md",
        "date": "2026-09-16",
        "scope": "拍照搜题 / 解答",
        "context": "通用大模型解题路线常与老师课上方法不一致，导致批改对不上；和稀泥式"
        "「两种都对」结论对学习无益。",
        "decision": (
            "解题路线**优先跟老师课上方法**（检索笔记驱动）；AI **不参考笔记**先独立解一遍作校验；"
            "两路线比对——一致则确认，冲突则深挖原因（符号约定/转写错误/题目理解）并给出**唯一结论**，"
            "**禁止并列两种答案**。"
        ),
        "rationale": "保证答案符合批改标准，同时用独立解暴露潜在错误。",
    },
    {
        "id": "ADR-005",
        "title": "部署形态解耦",
        "filename": "ADR-005-部署形态解耦.md",
        "date": "2026-09-16",
        "scope": "部署 / 配置",
        "context": "需要既能跑在宿舍 Windows 本地（离线、本机 GPU），又能部署到云端（公网、按量计费）。",
        "decision": (
            "后端与部署形态解耦：**同一套代码**通过配置切换 ``deployment_mode``（local/cloud）；"
            "差异收口于 ``AppConfig`` + ``ProviderRegistry`` + FastAPI 依赖注入四个点"
            "（DB 方言 / 文件落地 / 转写算力 / 鉴权与传输）。"
        ),
        "rationale": "避免维护两套代码；业务服务层对部署差异完全无感。",
    },
    {
        "id": "ADR-006",
        "title": "笔记多端同步（三处并存 + 冲突保留两份）",
        "filename": "ADR-006-笔记多端同步.md",
        "date": "2026-09-16",
        "scope": (
            "数据模型（Note / NoteRevision / SyncState）、NoteStore 端口层、同步协议、"
            "Android 本地库、API（/api/sync/*）"
        ),
        "supersedes": "Q-11（Obsidian 单一真相源）",
        "revision": "2026-09-16 修订：同步方向细化（区分正文与批注），决策本质未变",
        "context": (
            "原始决策 Q-11 为「**Obsidian 为唯一真相源，App 不维护笔记副本，App 内只建只索引不存正文的检索索引**」。"
            "该决策只在「索引加速检索」前提下成立，**未考虑用户需脱离 Win 使用**。用户补充诉求（原话）："
            "「就是云端同步笔记以及在模型需要笔记内容是也可以在安卓端没有 win 支持的情况下可以做到」；"
            "「或者是在安卓端可以直接调用本地的笔记就是安卓手机里的笔记内容」。"
            "由此暴露原前提三处不足："
            "① Win 一关机，Android 端无法让 AI 读到笔记正文"
            "（生成笔记要读教材导览与已有笔记、搜题要检索老师讲法）——若只有索引没有正文，链路断裂；"
            "② Android 端无法离线读笔记、离线检索；"
            "③ 三处（Win / 云端 / Android）需**保持一致**，而非单点权威。"
        ),
        "decision": (
            "① **三处并存**：Win Obsidian 目录 / 云端存储 / Android 本地库**各持一份笔记 Markdown 全文**；"
            "**同步方向**（v3.1 细化）：**正文** `Win ↔ 云端` **双向**、"
            "`云端 → Android` **单向下行（手机只读正文、不改正文）**；"
            "**批注**（**独立存储、不覆盖 Obsidian 原文**）`Android → 云端 → Win` **单向上行**，"
            "以稳定 `note_id` **关联**（**不用文件路径**——笔记可能改名/移动，用路径会让批注断链）。"
            "② **同步范围**：只同步笔记 Markdown；转写原文与教材扫描图不预同步、按需从服务端拉取。"
            "③ **权威模型**：**服务端只做「写入协调者」，不做「内容权威」**；每个副本携带 "
            "`note_id`（稳定逻辑身份）/ `content_hash`(sha256) / `updated_at` / `origin` / `deleted`；"
            "判定「谁新」**一律用 hash + mtime，不用「谁在哪台机器」**。"
            "④ **冲突策略 keep-both**：多端都改且内容不同时**两份都保留**"
            "（规范文件 + 冲突副本 + `NoteRevision` 留档），**绝不静默覆盖**，"
            "由用户在两端「冲突处理页」三选一（keep_remote / keep_local / keep_both）。"
            "⑤ **删除语义**：一律**软删除**（tombstone 传播），避免「一端删除、另一端复活」；「删除 vs 修改」按冲突处理。"
            "⑥ **同步口径**：**延迟但不丢数据**，不承诺后台实时同步。"
            "⑦ **离线能力边界**（FR-32）：连上任一服务器=功能完整；都连不上=只读本地笔记 + 全文检索 + 查看已有记录，"
            "**AI 解题需联网**；**明确不做手机端本地大模型推理**。"
            "⑧ **索引语义分化**：服务端 `SearchIndex` **不存正文**；"
            "Android 本地库 `LocalNoteIndex`（**客户端实体，服务端不建表**）**存正文**，配 SQLite FTS5。"
        ),
        "rationale": (
            "用户核心诉求是「脱离 Win 也能用笔记、让 AI 读正文作答」，单一真相源无法满足；"
            "**手机只读正文 + 仅编辑批注**，故**正文冲突只可能发生在 `Win ↔ 云端` 两侧**，"
            "批注走独立上行链路、不改动正文。hash + mtime 判新旧避免依赖多端时钟一致；"
            "keep-both 保证**任何一端的改动都不会被静默丢弃**，代价是偶发冲突副本，由用户可控裁决。"
            "此决策**推翻 Q-11**，故以 ADR-006 记录。"
        ),
        "alternatives": (
            "- **维持 Q-11**（Obsidian 唯一源 + 只存索引）：无法满足「脱离 Win 让 AI 读笔记正文」，"
            "Android 无法离线读全文。\n"
            "- **「权威随服务端所在侧走」**（初版设想）：用户在 Win 上直接编辑 Obsidian 属**带外写入**，"
            "会被服务端当脏数据覆盖，**违背「不静默覆盖」**。\n"
            "- **端上本地大模型推理**以支持离线 AI 解题：公式与术语错误率显著上升、耗电发热严重"
            " → 明确范围排除（PRD §3.2）。\n"
            "- **用文件路径关联批注**（而非 `note_id`）：笔记改名/移动即断链 → 改用稳定 `note_id`。"
        ),
        "consequences": (
            "- **正面**：Android 脱离 Win 可读 / 可检索 / 可让 AI 基于笔记作答；数据不丢（keep-both）；离线可复习。\n"
            "- **代价（含负面）**：引入同步复杂度（diff / 冲突 / 删除传播）；Android 需本地库与后台同步调度；"
            "**手机不能编辑正文**（能力上的妥协，协作式编辑不可用）；存储增大（但仅 Markdown，实测 < 20 MB）。\n"
            "- **约束**：Android **不承诺后台实时同步**（Doze / ROM 省电限制，`WorkManager` ≥ 15 min）；"
            "「同步延迟但不丢数据」为验收口径。"
        ),
        "tech_notes": (
            "- **新增仓储 / 端口层**：`app/repositories/note_store.py`（`NoteStore` 端口）"
            " + `note_store_local.py`（`ObsidianNoteStore`）/ `note_store_cloud.py`（`CloudNoteStore`）；"
            "Android 侧 `LocalNoteStore` / `SyncedNoteStore`。\n"
            "- 调用链：**Service → NoteStore（领域端口）→ StorageProvider（机制）**；"
            "`StorageProvider` 保持纯 blob 语义。\n"
            "- 同步协议与接口见架构文档 §3.6；Android 本地库见 §3.7；离线矩阵见 §3.8。"
        ),
    },
    {
        "id": "ADR-007",
        "title": "笔记第 10 节改为「学习建议」（不生成自测题）",
        "filename": "ADR-007-笔记不生成自测题.md",
        "date": "2026-09-18",
        "scope": "笔记生成 / 模板 / note_fused.md prompt / FIXED_CONVENTIONS",
        # 部分精化（refines）而非取代（supersedes）：ADR-001 其余格式仍有效，仅第 10 节内涵收窄。
        # 渲染为 `- **部分精化（refines）**：ADR-001`，置于 supersedes 行之后（见 _render_adr_md）。
        "refines": "ADR-001",
        "context": (
            "ADR-001 定义融合式单文件的固定结构，第 10 节原为「学习建议与自测」，"
            "且 ADR-001 的理由正是「固定结构可被代码确定性渲染，避免模型裁剪规则」。"
            "但实际生成中，自测题由 LLM 现编，质量不稳定（脱离本课重点、答案错误、低水平重复），"
            "且用户的「自测/练习」环节在 Obsidian 端自行承担。用户已明确决定：笔记不生成自测题，"
            "第 10 节只保留「学习建议」。该决定此前未以 ADR 留痕，导致 ADR-001（写\"必须有学习建议与自测\"）"
            "与 `server/config/prompts/note_fused.md`（硬约束\"绝对不要生成自测题\"）表面冲突，"
            "接手模型可能误判为 bug 并去\"修复\"。"
        ),
        "decision": (
            "笔记第 10 节由「学习建议与自测」改为「学习建议」：只提供课后复习策略、掌握优先级与知识迁移建议，"
            "**不生成自测题、练习题或折叠答案**。本 ADR **部分精化** ADR-001（`refines`，**非** `supersedes`）"
            "——融合式单文件、Mermaid mindmap、`> [!tip] 💡 拓展` callout、出处标记等其余格式**仍然有效**，"
            "仅第 10 节内涵收窄。"
        ),
        "rationale": (
            "1. **用户明确选择**：笔记只保留学习建议，不要自测题。\n"
            "2. **质量不可控**：自测题由 LLM 现编，易脱离本课重点、出现答案错误或低水平重复，反而干扰复习。\n"
            "3. **场景已由别处承担**：用户的\"自测/练习\"在 Obsidian 端自行组织，无需笔记内再生成一份。\n"
            "4. **消除文档—实现冲突**：`note_fused.md` 早已按\"不生成自测题\"执行，ADR-001 却写\"必须有自测\"；"
            "不留痕会让接手模型误判为 bug。"
        ),
        "alternatives": (
            "- **维持「学习建议与自测」**：自测题质量不稳定且与用户实际复习方式不符；用户已明确否定。\n"
            "- **改为可选自测（按配置开关）**：引入用户并不需要的开关，且仍需面对自测题质量不可控；无实际收益。\n"
            "- **保留自测但在 prompt 强化题目质量**：LLM 现编题目的质量波动无法靠 prompt 完全消除；不如直接不生成。"
        ),
        "consequences": (
            "- **正面**：笔记不再含易错、低质的自测题，复习信息更聚焦；prompt 与 ADR 口径一致，接手模型不会再误判为 bug；"
            "`FIXED_CONVENTIONS` 第 1 条恢复完整结构枚举。\n"
            "- **代价（含负面）**：笔记对\"自测\"这一学习环节**不再自给自足**——用户若要自测需另寻途径"
            "（自行在 Obsidian 组织练习或借助其他工具）。\n"
            "- **约束**：结构仍为固定单文件、不可裁剪；本次仅收窄第 10 节，其余小节不变。"
        ),
    },
)


class _TaskDef(BaseModel):
    """任务定义（用于扫描代码库判定完成状态）。"""

    task_id: str
    milestone: str
    title: str
    artifacts: list[str] = []
    depends_on: list[str] = []
    blocked_reason: str | None = None


TASK_DEFS: tuple[_TaskDef, ...] = (
    # ---- M0 项目地基（文件级）----
    _TaskDef(
        task_id="T0-01",
        milestone="M0",
        title="仓库骨架与工程约定",
        artifacts=[
            "README.md",
            ".gitignore",
            ".editorconfig",
            "docs/class-diagram.mermaid",
            "docs/sequence-diagram.mermaid",
        ],
    ),
    _TaskDef(
        task_id="T0-02",
        milestone="M0",
        title="后端依赖与运行入口",
        artifacts=[
            "server/pyproject.toml",
            "server/requirements.txt",
            "server/.env.example",
            "server/app/__init__.py",
            "server/app/main.py",
        ],
        depends_on=["T0-01"],
    ),
    _TaskDef(
        task_id="T0-03",
        milestone="M0",
        title="配置系统（本地/云端单一入口）",
        artifacts=[
            "server/app/config.py",
            "server/config/config.local.yaml",
            "server/config/config.cloud.yaml",
            "server/app/deps.py",
            "server/app/logging_setup.py",
            "server/app/errors.py",
        ],
        depends_on=["T0-02"],
    ),
    _TaskDef(
        task_id="T0-04",
        milestone="M0",
        title="数据层基座（服务端 18 实体 + 客户端 1 实体）",
        artifacts=[
            "server/app/db/base.py",
            "server/app/db/session.py",
            "server/app/db/models.py",
            "server/app/db/repositories.py",
            "server/app/schemas/common.py",
        ],
        depends_on=["T0-03"],
    ),
    _TaskDef(
        task_id="T0-05",
        milestone="M0",
        title="Provider 抽象层接口",
        artifacts=[
            "server/app/providers/base.py",
            "server/app/providers/registry.py",
        ],
        depends_on=["T0-03"],
    ),
    _TaskDef(
        task_id="T0-06",
        milestone="M0",
        title="转写 Provider 三实现",
        artifacts=[
            "server/app/providers/transcription/local_gpu.py",
            "server/app/providers/transcription/cloud_api.py",
            "server/app/providers/transcription/on_device.py",
        ],
        depends_on=["T0-05"],
    ),
    _TaskDef(
        task_id="T0-07",
        milestone="M0",
        title="LLM Provider 实现",
        artifacts=[
            "server/app/providers/llm/cloud_llm.py",
            "server/app/providers/llm/local_llm.py",
        ],
        depends_on=["T0-05"],
    ),
    _TaskDef(
        task_id="T0-08",
        milestone="M0",
        title="视觉/多模态 Provider 实现",
        artifacts=[
            "server/app/providers/vision/cloud_vision.py",
            "server/app/providers/vision/local_vision.py",
        ],
        depends_on=["T0-05"],
    ),
    _TaskDef(
        task_id="T0-09",
        milestone="M0",
        title="存储 Provider 实现",
        artifacts=[
            "server/app/providers/storage/local_fs.py",
            "server/app/providers/storage/object_store.py",
        ],
        depends_on=["T0-05"],
    ),
    _TaskDef(
        task_id="T0-10",
        milestone="M0",
        title="交接包生成器（FR-16）",
        artifacts=[
            "server/app/services/handoff_service.py",
            "server/config/prompts/handoff_summary.md",
            "scripts/generate_handoff.py",
        ],
        depends_on=["T0-03", "T0-05", "T0-07"],
    ),
    _TaskDef(
        task_id="T0-11",
        milestone="M0",
        title="API 骨架 + health/settings/handoff 路由",
        artifacts=[
            "server/app/api/__init__.py",
            "server/app/api/health.py",
            "server/app/api/settings.py",
            "server/app/api/handoff.py",
            "server/app/core/security.py",
            "server/app/core/tasks.py",
            "server/app/core/ids.py",
            "server/app/schemas/provider.py",
        ],
        depends_on=["T0-03", "T0-04", "T0-10"],
    ),
    _TaskDef(
        task_id="T0-12",
        milestone="M0",
        title="ADR 初始文档 + 冒烟测试",
        artifacts=[
            "server/tests/conftest.py",
            "server/tests/test_config.py",
            "server/tests/test_providers_registry.py",
            "server/tests/test_handoff_schema.py",
            "scripts/dev_server.ps1",
            "scripts/run_tests.ps1",
        ],
        depends_on=["T0-10", "T0-11"],
    ),
    # ---- M1 课表（模块级）----
    _TaskDef(
        task_id="T1-01",
        milestone="M1",
        title="课表与课程数据/服务",
        artifacts=[
            "server/app/services/course_service.py",
            "server/app/services/schedule_service.py",
            "server/app/api/courses.py",
            "server/app/api/schedule.py",
        ],
        depends_on=["T0-04"],
    ),
    _TaskDef(
        task_id="T1-02",
        milestone="M1",
        title="截图 OCR 录课表",
        artifacts=["server/app/services/schedule_service.py"],
        depends_on=["T1-01", "T0-08"],
    ),
    _TaskDef(
        task_id="T1-03",
        milestone="M1",
        title="上课提醒判定",
        artifacts=["server/app/services/scheduler_service.py"],
        depends_on=["T1-01"],
    ),
    # ---- M2 转写闭环 ----
    _TaskDef(
        task_id="T2-01",
        milestone="M2",
        title="录音导入/登记 + 分片上传",
        artifacts=[
            "server/app/services/recording_service.py",
            "server/app/api/recordings.py",
        ],
        depends_on=["T0-09", "T0-11"],
    ),
    _TaskDef(
        task_id="T2-02",
        milestone="M2",
        title="转写任务 + 队列（local_gpu）",
        artifacts=[
            "server/app/services/transcription_service.py",
            "server/app/api/transcription.py",
        ],
        depends_on=["T0-06", "T2-01"],
    ),
    _TaskDef(
        task_id="T2-03",
        milestone="M2",
        title="术语校正 + 勘误表 + 转写原文归档",
        artifacts=["server/app/services/obsidian_service.py"],
        depends_on=["T2-02", "T3-01"],
    ),
    # ---- M3 笔记生成 ----
    _TaskDef(
        task_id="T3-01",
        milestone="M3",
        title="Obsidian 读写 + 归档/命名/清单登记",
        artifacts=[
            "server/app/services/obsidian_service.py",
            "server/app/services/archive_service.py",
        ],
        depends_on=["T0-04"],
    ),
    _TaskDef(
        task_id="T3-02",
        milestone="M3",
        title="融合式笔记生成（模板 + LLM 结构化）",
        artifacts=[
            "server/app/pipelines/note_pipeline.py",
            "server/app/pipelines/templates/note_template.py",
            "server/app/services/note_service.py",
            "server/app/api/notes.py",
        ],
        depends_on=["T3-01", "T0-07"],
    ),
    _TaskDef(
        task_id="T3-03",
        milestone="M3",
        title="教材回填 + ◉课件/◉教材 标记",
        artifacts=[
            "server/app/services/textbook_service.py",
            "server/app/pipelines/backfill_pipeline.py",
            "server/app/api/textbooks.py",
        ],
        depends_on=["T3-02", "T0-08"],
    ),
    # ---- M4 拍照搜题 ----
    _TaskDef(
        task_id="T4-01",
        milestone="M4",
        title="OCR 识题 + 笔记检索（老师路线）",
        artifacts=[
            "server/app/services/index_service.py",
            "server/app/api/search.py",
        ],
        depends_on=["T3-01", "T0-08"],
    ),
    _TaskDef(
        task_id="T4-02",
        milestone="M4",
        title="独立解 + 交叉比对 + 解答记录",
        artifacts=[
            "server/app/pipelines/homework_pipeline.py",
            "server/app/services/homework_service.py",
            "server/app/api/homework.py",
        ],
        depends_on=["T4-01", "T0-07"],
    ),
    # ---- M5 Android 端 ----
    _TaskDef(
        task_id="T5-01",
        milestone="M5",
        title="Flutter 端骨架",
        artifacts=["app/lib/main.dart", "app/pubspec.yaml"],
        depends_on=["T0-01"],
    ),
    _TaskDef(
        task_id="T5-02",
        milestone="M5",
        title="Platform Channel 录音桥接（最高风险）",
        artifacts=[
            "app/lib/platform/recording_bridge.dart",
            "app/android/app/src/main/kotlin/audio/AudioRecordService.kt",
        ],
        depends_on=["T5-01"],
    ),
    _TaskDef(
        task_id="T5-03",
        milestone="M5",
        title="后台上传 + 笔记阅读 + 拍照搜题 UI",
        artifacts=["app/lib/data/upload_queue.dart", "app/lib/features/notes/notes_page.dart"],
        depends_on=["T5-02", "T2-01", "T4-02"],
    ),
    # ---- M6 云端模式 ----
    _TaskDef(
        task_id="T6-01",
        milestone="M6",
        title="云端配置 + Postgres + 对象存储接线",
        artifacts=["server/config/config.cloud.yaml"],
        depends_on=["T0-03", "T0-09"],
    ),
    _TaskDef(
        task_id="T6-02",
        milestone="M6",
        title="cloud_api 转写上线 + 用量统计/阈值",
        artifacts=[
            "server/app/services/usage_service.py",
            "server/app/api/usage.py",
        ],
        depends_on=["T0-06", "T2-02"],
    ),
    _TaskDef(
        task_id="T6-03",
        milestone="M6",
        title="云端基础鉴权 + HTTPS",
        artifacts=["server/app/core/security.py"],
        depends_on=["T0-11"],
    ),
)

MILESTONE_STAGES: dict[str, str] = {
    "M0": "项目地基",
    "M1": "课表",
    "M2": "转写闭环",
    "M3": "笔记生成",
    "M4": "拍照搜题",
    "M5": "Android 端",
    "M6": "云端模式",
}

# 交接包生成路由所在目录，其下文件由本服务产出，不参与"任务完成度"判定
_HANDOFF_OUTPUT_PREFIX = "docs/handoff"


class _ProjectSummary(BaseModel):
    """LLM 结构化输出：进度总结。"""

    summary: str = ""
    stage_summary: str = ""


class HandoffService:
    """交接包生成服务。"""

    def __init__(self, config: AppConfig, llm_provider: LLMProvider | None = None) -> None:
        self._config = config
        self._llm = llm_provider
        self._output_dir: Path = config.resolved_handoff_dir

    # ------------------------------------------------------------------
    # 扫描
    # ------------------------------------------------------------------
    @staticmethod
    def scan_codebase() -> list[str]:
        """扫描后端代码库，返回相对项目根的路径列表（升序）。"""
        base = PROJECT_ROOT / "server" / "app"
        if not base.exists():
            return []
        return sorted(
            path.relative_to(PROJECT_ROOT).as_posix()
            for path in base.rglob("*.py")
            if "__pycache__" not in path.parts
        )

    @staticmethod
    def _artifact_exists(rel_path: str) -> bool:
        return (PROJECT_ROOT / rel_path).exists()

    def _checkable_artifacts(self, task: _TaskDef) -> list[str]:
        """过滤掉由本服务产出的文件（避免"自己证明自己"）。"""
        return [a for a in task.artifacts if not a.startswith(_HANDOFF_OUTPUT_PREFIX)]

    def _evaluate_tasks(self) -> tuple[list[TaskRef], list[TaskRef], list[TaskRef], list[TaskRef]]:
        """扫描代码库，判定 done / in_progress / todo / blocked。"""
        done: list[TaskRef] = []
        todo: list[TaskRef] = []
        blocked: list[TaskRef] = []
        in_progress: list[TaskRef] = []

        for task in sorted(TASK_DEFS, key=lambda t: t.task_id):
            if task.blocked_reason:
                blocked.append(
                    TaskRef(
                        task_id=task.task_id,
                        title=task.title,
                        reason=task.blocked_reason,
                        depends_on=task.depends_on,
                    )
                )
                continue
            checkable = self._checkable_artifacts(task)
            is_done = bool(checkable) and all(self._artifact_exists(a) for a in checkable)
            if is_done:
                done.append(
                    TaskRef(
                        task_id=task.task_id,
                        title=task.title,
                        artifacts=checkable,
                    )
                )
            else:
                todo.append(
                    TaskRef(
                        task_id=task.task_id,
                        title=task.title,
                        artifacts=checkable,
                        depends_on=task.depends_on,
                    )
                )
        return done, in_progress, todo, blocked

    # ------------------------------------------------------------------
    # 汇总（LLM 可选，失败降级）
    # ------------------------------------------------------------------
    def _fallback_summary(
        self, milestone: str, stage: str, done: list[TaskRef], todo: list[TaskRef]
    ) -> _ProjectSummary:
        """确定性总结（LLM 不可用时的降级路径）：计数与阶段进度保持一致。"""
        milestone_ids = {task.task_id for task in TASK_DEFS if task.milestone == milestone}
        done_in_milestone = sum(1 for item in done if item.task_id in milestone_ids)
        total_in_milestone = len(milestone_ids)
        next_task = todo[0].title if todo else "无"
        return _ProjectSummary(
            summary=(
                f"{milestone}（{stage}）进展：阶段任务 {done_in_milestone}/{total_in_milestone} 已完成，"
                f"下一步为「{next_task}」。"
            ),
            stage_summary=(
                f"当前处于 {milestone}（{stage}）阶段，阶段任务已完成 {done_in_milestone}/"
                f"{total_in_milestone}，全局剩余待办 {len(todo)} 个。"
                "所有规则性约束（conventions）由代码固定注入，换模型接手时不会丢失。"
            ),
        )

    async def _summarize(
        self,
        milestone: str,
        stage: str,
        done: list[TaskRef],
        todo: list[TaskRef],
        blocked: list[TaskRef],
    ) -> _ProjectSummary:
        """尝试用 LLM 生成总结；任何失败均降级为确定性文本。"""
        if self._llm is None:
            return self._fallback_summary(milestone, stage, done, todo)
        try:
            system_prompt = self._load_prompt()
            context = {
                "milestone": milestone,
                "stage": stage,
                "done": [t.model_dump() for t in done],
                "todo": [t.model_dump() for t in todo],
                "blocked": [t.model_dump() for t in blocked],
                "key_paths": self._key_paths(),
                "environment_facts": list(ENVIRONMENT_FACTS),
            }
            messages = [
                LLMMessage(role="system", content=system_prompt),
                LLMMessage(
                    role="user",
                    content="上下文（JSON）：\n"
                    + json.dumps(context, ensure_ascii=False, indent=2),
                ),
            ]
            result = await self._llm.complete_structured(messages, _ProjectSummary)
            if not result.summary:
                return self._fallback_summary(milestone, stage, done, todo)
            return result  # type: ignore[return-value]
        except ProviderError as exc:
            _log.warning("handoff_summary_llm_failed", error=str(exc), fallback=True)
        except Exception as exc:  # noqa: BLE001 - 汇总绝不阻断交接包生成
            _log.warning("handoff_summary_unexpected", error=str(exc), fallback=True)
        return self._fallback_summary(milestone, stage, done, todo)

    @staticmethod
    def _load_prompt() -> str:
        prompt_file = CONFIG_DIR / "prompts" / "handoff_summary.md"
        if prompt_file.exists():
            return prompt_file.read_text(encoding="utf-8")
        return "你是技术交接官，请用中文生成简洁的项目进度总结。"

    def _key_paths(self) -> dict[str, str]:
        return {
            "obsidian_root": self._config.obsidian_root,
            "textbook_root": self._config.textbook_root,
            "server_entry": "server/app/main.py",
            "flutter_entry": "app/lib/main.dart",
            "handoff_dir": str(self._output_dir),
        }

    # ------------------------------------------------------------------
    # 生成
    # ------------------------------------------------------------------
    async def generate(self, milestone: str = "M0", stage: str | None = None) -> dict[str, Any]:
        """生成交接包四份文件并返回结构化结果。

        :returns: ``{"handoff": dict, "files": list[str], "output_dir": str}``
        """
        resolved_stage = stage or MILESTONE_STAGES.get(milestone, "")
        done, in_progress, todo, blocked = self._evaluate_tasks()
        summary = await self._summarize(milestone, resolved_stage, done, todo, blocked)

        # 阶段进度按**当前里程碑**统计（done / todo 列表仍跨里程碑展示）
        done_ids = {task.task_id for task in done}
        milestone_tasks = [task for task in TASK_DEFS if task.milestone == milestone]
        completed_in_milestone = sum(1 for task in milestone_tasks if task.task_id in done_ids)

        generated_at = _now_iso()
        handoff = HandoffJson(
            generated_at=generated_at,
            milestone=milestone,
            stage=resolved_stage,
            stage_progress=StageProgress(
                completed_tasks=completed_in_milestone, total_tasks=len(milestone_tasks)
            ),
            summary=summary.summary,
            done=done,
            in_progress=in_progress,
            todo=todo,
            blocked=blocked,
            conventions=list(FIXED_CONVENTIONS),
            decisions=[
                {"id": adr["id"], "title": adr["title"], "file": f"decisions/{adr['filename']}"}
                for adr in ADR_DEFS
            ],
            key_paths=self._key_paths(),
            environment_facts=list(ENVIRONMENT_FACTS),
        )

        files = self._write_handoff_files(handoff, summary)
        _log.info(
            "handoff_generated",
            milestone=milestone,
            stage=resolved_stage,
            done=len(done),
            todo=len(todo),
            blocked=len(blocked),
            files=len(files),
        )
        return {
            "handoff": handoff.model_dump(by_alias=True),
            "files": files,
            "output_dir": str(self._output_dir),
        }

    # ------------------------------------------------------------------
    # 落盘
    # ------------------------------------------------------------------
    def _write_handoff_files(self, handoff: HandoffJson, summary: _ProjectSummary) -> list[str]:
        """写出四类文件；返回相对项目根的路径列表。"""
        self._output_dir.mkdir(parents=True, exist_ok=True)
        decisions_dir = self._output_dir / "decisions"
        decisions_dir.mkdir(parents=True, exist_ok=True)

        written: list[str] = []

        # 1) handoff.json（机读，整体覆盖）
        handoff_file = self._output_dir / "handoff.json"
        handoff_file.write_text(
            json.dumps(handoff.model_dump(by_alias=True), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        written.append(self._rel(handoff_file))

        # 2) AGENTS.md（入口，结构稳定）
        agents_file = self._output_dir / "AGENTS.md"
        agents_file.write_text(self._render_agents_md(handoff), encoding="utf-8")
        written.append(self._rel(agents_file))

        # 3) PROJECT_STATE.md（人读，整体覆盖）
        state_file = self._output_dir / "PROJECT_STATE.md"
        state_file.write_text(
            self._render_project_state_md(handoff, summary), encoding="utf-8"
        )
        written.append(self._rel(state_file))

        # 4) decisions/ADR-*.md
        #    默认**只增不改**：仅当文件不存在时写出。
        #    例外：带 ``revision``（表述精确化）的 ADR 允许刷新，把「修订记录」写进文件（见 ADR-006）。
        for adr in ADR_DEFS:
            adr_file = decisions_dir / adr["filename"]
            if (not adr_file.exists()) or adr.get("revision"):
                adr_file.write_text(self._render_adr_md(adr), encoding="utf-8")
            written.append(self._rel(adr_file))

        return written

    @staticmethod
    def _rel(path: Path) -> str:
        try:
            return path.relative_to(PROJECT_ROOT).as_posix()
        except ValueError:
            return path.as_posix()

    # ------------------------------------------------------------------
    # 渲染
    # ------------------------------------------------------------------
    def _render_agents_md(self, handoff: HandoffJson) -> str:
        conventions = "\n".join(f"{i}. {c}" for i, c in enumerate(handoff.conventions, start=1))
        env_facts = "\n".join(f"- {f}" for f in handoff.environment_facts)
        decisions = "\n".join(
            f"- [{d['id']}]({d['file']})：{d['title']}" for d in handoff.decisions
        )
        key_paths = "\n".join(f"- `{k}`：`{v}`" for k, v in handoff.key_paths.items())
        return f"""# AGENTS.md —— 接手入口

> 本文件由 `HandoffService`（FR-16）生成，结构稳定；**硬约定清单由代码固定注入**。
> 生成时间：{handoff.generated_at} ｜ 当前里程碑：**{handoff.milestone}（{handoff.stage}）**

## 1. 项目是什么

**remember（ClassNotes Assistant）**—— 把已在电脑上跑通的「离线 AI 学习工作流」
（上课录音 → 转写 → 融合式课堂笔记 → 拍照搜题）产品化为**双端（Windows + Android）**软件。
用户为深圳全日制本科生（机械类），本学期四门课：工程力学 / 普通物理1 / 线性代数 / 电工电子。

## 2. 技术栈

- 客户端：**Flutter 3.x（Dart 3）** + Riverpod + go_router + dio；录音走**自研 Kotlin Platform Channel**。
- 后端：**Python 3.13 + FastAPI + SQLAlchemy 2.0（async）**；Provider 抽象层支撑本地/云端同码切换。
- 数据：SQLite（本地）/ Postgres（云端）；文件：本地目录（`./data`）/ 对象存储。
- 转写：本地 `faster-whisper-medium`（**AMD ROCm**）或云 ASR（Provider 可替换）。
- 数据资产根：Obsidian 库 `{handoff.key_paths.get("obsidian_root", "")}`
  （笔记**三处并存**之一；另两处为**云端存储**与 **Android 本地库**，冲突保留两份、绝不静默覆盖；同步方向见 §4 硬约定）。

## 3. 怎么跑起来

```powershell
# 安装依赖（用项目 venv，勿污染全局）
python -m pip install -r server/requirements.txt

# 本地模式
./scripts/dev_server.ps1
# 云端模式
./scripts/dev_server_cloud.ps1

# 测试
./scripts/run_tests.ps1

# 生成交接包
cd server && python ../scripts/generate_handoff.py --milestone {handoff.milestone}
```

## 4. 硬约定清单（不得改动）

{conventions}

## 5. 环境事实

{env_facts}

## 6. 决策记录（ADR，只增不改）

{decisions}

## 7. 关键路径

{key_paths}
"""

    def _render_project_state_md(self, handoff: HandoffJson, summary: _ProjectSummary) -> str:
        def _render_tasks(tasks: list[TaskRef], with_reason: bool = False) -> str:
            if not tasks:
                return "_（无）_\n"
            lines = []
            for t in tasks:
                suffix = ""
                if with_reason and t.reason:
                    suffix = f" —— 阻塞原因：{t.reason}"
                elif t.depends_on:
                    suffix = f" （依赖：{', '.join(t.depends_on)}）"
                lines.append(f"- **{t.task_id}** {t.title}{suffix}")
            return "\n".join(lines) + "\n"

        return f"""# PROJECT_STATE.md —— 项目状态

> 由 `HandoffService`（FR-16）生成，**每次生成整体覆盖**。
> 生成时间：{handoff.generated_at}

## 当前阶段

- **里程碑**：{handoff.milestone}（{handoff.stage}）
- **进度**：{handoff.stage_progress.completed_tasks} / {handoff.stage_progress.total_tasks} 个任务已完成

## 一句话总结

{handoff.summary}

## 阶段总结

{summary.stage_summary}

## ✅ 已完成（{len(handoff.done)}）

{_render_tasks(handoff.done)}
## 🔄 进行中（{len(handoff.in_progress)}）

{_render_tasks(handoff.in_progress)}
## 📋 待办（{len(handoff.todo)}）

{_render_tasks(handoff.todo)}
## ⛔ 阻塞（{len(handoff.blocked)}）

{_render_tasks(handoff.blocked, with_reason=True)}
## 📌 硬约定（由代码固定注入，不得由模型改写）

{chr(10).join(f"- {c}" for c in handoff.conventions)}
"""

    @staticmethod
    def _render_adr_md(adr: dict[str, str]) -> str:
        """渲染单篇 ADR。

        可选小节（``alternatives`` / ``consequences`` / ``tech_notes``）**按有无输出**：
        ADR-001~005 无此三节则自然省略，ADR-006 有则完整呈现（信息量 ≥ 手写详细版）。
        """
        supersedes = adr.get("supersedes")
        supersedes_line = f"\n- **取代（supersedes）**：{supersedes}" if supersedes else ""
        # 部分精化（refines）：决策未推翻、仅对某篇 ADR 做局部细化（见 ADR-007）。
        # 与 supersedes 互斥语义：supersedes=推翻旧的，refines=精化旧的（旧的仍有效）。
        refines = adr.get("refines")
        refines_line = f"\n- **部分精化（refines）**：{refines}" if refines else ""

        def _section(heading: str, body: str | None) -> str:
            """有内容才渲染的小节，统一以空行分隔。"""
            if not body:
                return ""
            return f"\n## {heading}\n\n{body}\n"

        tech_notes_section = _section("技术落点", adr.get("tech_notes"))
        alternatives_section = _section("被否方案（Alternatives Considered）", adr.get("alternatives"))
        consequences_section = _section("后果（Consequences）", adr.get("consequences"))

        revision = adr.get("revision")
        revision_section = f"\n## 修订记录\n\n- {revision}\n" if revision else ""

        return f"""# {adr["id"]}：{adr["title"]}

- **日期**：{adr["date"]}
- **影响范围**：{adr["scope"]}
- **状态**：已采纳（Accepted）{supersedes_line}{refines_line}

## 背景（Context）

{adr["context"]}

## 决策（Decision）

{adr["decision"]}

## 理由（Rationale）

{adr["rationale"]}
{tech_notes_section}{alternatives_section}{consequences_section}{revision_section}
> 本 ADR **只增不改**：如需推翻，请新建 ADR-NNN 并标注 `supersedes: {adr["id"]}`。
"""


def _now_iso() -> str:
    """生成带时区偏移的 ISO 8601 时间戳（用于 handoff.json.generated_at）。"""
    from datetime import datetime

    return datetime.now().astimezone().isoformat(timespec="seconds")
