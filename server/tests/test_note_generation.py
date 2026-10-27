"""融合式单文件笔记生成逻辑与结构规范测试（含用户明确指示：自测已删除）。"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import AppConfig
from app.db.base import Base
from app.db.session import Database
from app.providers.base import LLMProvider, Message, ProviderCapabilities
from app.repositories.note_store_local import ObsidianNoteStore
from app.schemas.note import NoteGenerateRequest
from app.services.note_generation_service import NoteGenerationService


class MockLLMProvider(LLMProvider):
    """用于测试的模拟 LLM Provider。"""

    def __init__(self, response_text: str, config: object = None):
        super().__init__(config or {}, "mock_llm")
        self._response = response_text

    async def complete(self, messages: list[Message], **kwargs) -> str:
        # 如果是提取关键词
        if any("核心中文主题关键词" in (m.content or "") for m in messages):
            return "拉氏变换与稳定性"
        return self._response

    async def complete_structured(self, messages: list[Message], schema, **kwargs):
        raise NotImplementedError

    def count_tokens(self, text: str) -> int:
        return len(text)

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name="mock_llm",
            kind="llm",
            runs_offline=True,
            incurs_cost=False,
        )


MOCK_NOTE_MARKDOWN = r"""---
note_id: mock-note-id-123
course: 自动控制原理
lesson: 1
topic: 拉氏变换与稳定性
created: 2026-09-18 20:00:00
format: 融合式（课堂实录 + 拓展讲解）
origin: win
tags: [课堂笔记, 自动控制原理]
---

# 拉氏变换与稳定性（2026-09-18）

## 概述
本次课系统介绍了控制工程中的拉普拉斯变换原理与线性系统稳定性分析。阐明了复频域建模的核心优势。为后续频率响应与根轨迹分析奠定坚实数学基石。

## 知识架构（Mindmap）
```mermaid
mindmap
  root((控制系统稳定性))
    复频域变换
      拉氏变换定义
      常用反变换
    代数判据
      劳斯判据
      赫尔维茨判据
```

## 核心知识点
### 1. 拉氏变换定义与收敛域 ◉课堂
拉普拉斯变换通过积分因子 $e^{-st}$ 将时域微分方程转化为复频域代数方程。

> [!tip] 💡 拓展｜拉普拉斯变换本质
> - **为什么**：时域微分与卷积运算在频域转化为乘法运算，极大简化求解复杂度。
> - **怎么用**：查阅拉氏变换表结合部分分式展开法求解反变换。
> - **陷阱**：务必注意初值定理与终值定理的极限存在前提条件。

### 2. 劳斯稳定判据 ◉课件 ◉教材
系统特征方程各项系数必须为正，且劳斯表第一列各元素符号相同。

> [!tip] 💡 拓展｜劳斯表计算技巧
> - **为什么**：无需直接因式分解高阶多项式即可判断右半复平面极点个数。
> - **怎么用**：按交叉相乘除以首项的标准递推公式构建表格。
> - **陷阱**：遇到首项为零时需用微小量 $\epsilon$ 替代，全零行需构造辅助多项式。

## 老师强调
期末考试必考劳斯表全零行处理，尤其是虚轴共轭极点振荡频率的计算！

## 事务待办
- [ ] 完成习题册第 3 章 3-4, 3-7 题
- [ ] 预习第 4 章根轨迹法基本法则

## 勘误表
| 误听/口误 | 纠正为 | 上下文与原因 |
|---|---|---|
| 劳斯表弟一行 | 劳斯表第一行 | 语音识别同音字 |

## ⚠️待确认
- 辅助多项式求导后的根与原方程根的对应关系需再核对教材 P112

## 学习建议
重点掌握劳斯表的递推填表规则及特殊情况判定流程，建议手算两道高阶闭环系统的经典考题。
"""


@pytest.fixture
async def service_env(tmp_path: Path):
    obsidian_root = tmp_path / "ObsidianVault"
    obsidian_root.mkdir()

    db_file = tmp_path / "test_gen.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    db = Database(db_url)
    config = AppConfig(obsidian_root=str(obsidian_root))
    store = ObsidianNoteStore(config=config, database=db)
    llm = MockLLMProvider(MOCK_NOTE_MARKDOWN)
    service = NoteGenerationService(
        config=config, database=db, llm_provider=llm, note_store=store
    )

    yield service, obsidian_root
    await engine.dispose()


@pytest.mark.asyncio
async def test_note_generation_structure_and_no_self_test(service_env):
    """验证生成的笔记严格遵守 ADR-001 小节，且自测已按要求彻底删除。"""
    service, root = service_env

    req = NoteGenerateRequest(
        course_name="自动控制原理",
        lesson=1,
        class_date="2026-09-18",
        topic="拉氏变换与稳定性",
    )

    dto, markdown, stats = await service.generate_note(req)

    # 1. 验证元数据
    assert dto.course_name == "自动控制原理"
    assert dto.topic == "拉氏变换与稳定性"
    assert dto.obsidian_path == "课堂笔记/自动控制原理/拉氏变换与稳定性_2026-09-18.md"

    # 2. 验证 ADR-001 必须包含的小节
    assert "## 概述" in markdown
    assert "## 知识架构（Mindmap）" in markdown
    assert "```mermaid\nmindmap" in markdown
    assert "## 核心知识点" in markdown
    assert "> [!tip] 💡 拓展｜" in markdown
    assert "## 老师强调" in markdown
    assert "## 事务待办" in markdown
    assert "- [ ]" in markdown
    assert "## 勘误表" in markdown
    assert "## ⚠️待确认" in markdown
    assert "## 学习建议" in markdown

    # 3. ★ 核心验证：用户指令「自测可以删掉」，确认自测题与自测模块绝对不存在
    assert "自测" not in markdown
    assert "自测题" not in markdown
    assert "<details><summary>" not in markdown

    # 4. 验证来源标记统计
    assert stats["classroom"] >= 1
    assert stats["courseware"] >= 1
    assert stats["textbook"] >= 1

    # 5. 验证文件物理落盘
    disk_file = root / dto.obsidian_path
    assert disk_file.is_file()
    assert "拉氏变换与稳定性" in disk_file.read_text(encoding="utf-8")


@pytest.mark.asyncio
async def test_filter_hallucinated_self_test():
    """测试当 LLM 偶尔幻觉输出自测内容时，过滤器能否将其精准截断抹除。"""
    dirty_markdown = (
        "## 概述\n内容\n\n"
        "## 学习建议\n建议好好复习。\n\n"
        "## 自测题\n1. 什么是劳斯判据？\n<details><summary>答案</summary>判据内容</details>\n"
    )
    service = NoteGenerationService(
        config=AppConfig(),
        database=AsyncMock(),
        llm_provider=MockLLMProvider(""),
        note_store=AsyncMock(),
    )
    cleaned = service._remove_self_test_sections(dirty_markdown)
    assert "自测" not in cleaned
    assert "什么是劳斯判据" not in cleaned
    assert "## 学习建议" in cleaned
