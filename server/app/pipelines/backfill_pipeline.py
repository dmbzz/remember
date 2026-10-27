"""教材回填流水线（Pipelines · 架构设计 §1.2、T3-03，ADR-004 / FR-09）。

核心规则：
- 教材回填只填教材确有内容，否则保留 ⚠️待确认，坚决不臆造（硬规则 #9）
- 版权边界：教材原图不进入笔记正文，仅允许摘录并打上 ◉教材 标记（硬规则 #10）
- 更新 ◉教材 计数并重新覆写落盘
"""

from __future__ import annotations

import re
from typing import Any

from app.config import AppConfig, get_app_config
from app.core.note_markers import count_markers
from app.db.models import Note
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.repositories.note_store import NoteStore
from app.services.textbook_service import TextbookService

__all__ = ["BackfillPipeline"]


class BackfillPipeline:
    """教材回填流水线。"""

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
        note_store: NoteStore | None = None,
        textbook_service: TextbookService | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()
        if note_store is not None:
            self.note_store = note_store
        else:
            from app.deps import get_note_store

            self.note_store = get_note_store()
        self.textbook_service = textbook_service or TextbookService(self.config, self.database)

    async def run(
        self,
        note_id: str,
        course_name: str | None = None,
    ) -> tuple[list[str], dict[str, int], bool]:
        """对指定笔记执行教材回填，返回 (backfilled_items, marker_stats, updated)。"""
        markdown, meta = await self.note_store.read(note_id)

        # 确定课程名
        c_name = course_name
        topic = "笔记"
        date_str = "2026-09-18"

        # 从 rel_path 提取课程名与主题
        # 例如 课堂笔记/自动控制原理/拉氏变换_2026-09-18.md
        parts = meta.rel_path.replace("\\", "/").split("/")
        if len(parts) >= 3:
            c_name = c_name or parts[1]
            filename = parts[2]
            if "_" in filename and filename.endswith(".md"):
                topic, date_str = filename[:-3].rsplit("_", 1)

        c_name = c_name or "未指定课程"

        # 检查 ## ⚠️待确认 小节
        pending_match = re.search(r"##\s*⚠️待确认\s*\n(.*?)(?=\n##|\Z)", markdown, flags=re.DOTALL)
        if not pending_match:
            return [], count_markers(markdown), False

        pending_block = pending_match.group(1)
        lines = pending_block.strip().splitlines()

        backfilled_items: list[str] = []
        new_lines: list[str] = []
        backfill_paragraphs: list[str] = []

        for line in lines:
            line_str = line.strip()
            if not line_str or line_str.startswith("（本次课逻辑完整") or "已核实" in line_str:
                new_lines.append(line_str)
                continue

            # 匹配页码线索，如 P112、P.112、第112页、page 112
            page_match = re.search(r"[Pp](?:age)?\.?\s*(\d+)|第\s*(\d+)\s*页", line_str)
            page_num: int | None = None
            if page_match:
                page_str = page_match.group(1) or page_match.group(2)
                page_num = int(page_str)

            found_text = ""
            if page_num:
                try:
                    found_text = await self.textbook_service.get_page_text(c_name, page_num)
                except Exception:
                    found_text = ""

            # 若未从页码命中，尝试按导览索引模糊匹配
            if not found_text:
                kw = line_str[:15].lstrip("-*•0123456789. ")
                indices = await self.textbook_service.query_index(c_name, knowledge_point=kw)
                if indices:
                    page_num = indices[0].printed_page
                    found_text = indices[0].summary

            if found_text:
                # 找到教材确凿内容，执行回填
                summary_excerpt = found_text[:120].replace("\n", " ").strip()
                item_desc = f"P{page_num}：{summary_excerpt}..." if page_num else summary_excerpt
                backfilled_items.append(f"{line_str} → {item_desc}")

                # 在待确认中标记已核对
                new_lines.append(f"- [x] （已由教材回填证实 ◉教材）{line_str}")

                # 构造回填补充 callout
                backfill_callout = (
                    f"\n> [!note] 📖 教材回填补充｜P{page_num} ◉教材\n"
                    f"> 根据教材对应章节说明：{summary_excerpt} ◉教材\n"
                )
                backfill_paragraphs.append(backfill_callout)
            else:
                # 坚决不脑补、不臆造，保留原样
                new_lines.append(line_str)

        if not backfilled_items:
            # 教材中确无对应内容，保持原样（遵循硬规则 #9）
            return [], count_markers(markdown), False

        # 重新组合 Markdown
        # 1. 更新 ⚠️待确认 区域
        new_pending_block = "\n".join(new_lines) + "\n"
        markdown = (
            markdown[: pending_match.start(1)]
            + new_pending_block
            + markdown[pending_match.end(1) :]
        )

        # 2. 将回填段落附加到 ## 核心知识点 末尾
        kp_match = re.search(r"##\s*核心知识点.*?(?=\n##|\Z)", markdown, flags=re.DOTALL)
        if kp_match:
            insert_pos = kp_match.end()
            insert_text = "\n".join(backfill_paragraphs) + "\n"
            markdown = markdown[:insert_pos] + insert_text + markdown[insert_pos:]
        else:
            markdown += "\n" + "\n".join(backfill_paragraphs)

        marker_stats = count_markers(markdown)

        # 重新落盘
        await self.note_store.write(
            course_name=c_name,
            topic=topic,
            date_str=date_str,
            markdown=markdown,
            note_id=note_id,
            marker_stats=marker_stats,
        )

        return backfilled_items, marker_stats, True
