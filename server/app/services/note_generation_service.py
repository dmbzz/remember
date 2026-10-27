"""融合式单文件笔记生成服务（架构设计 §3.4、§3.5，T3-02，ADR-001/002/006）。

职责：
- 组装课堂转写文本、勘误表与提示词
- 调度 LLM Provider 生成符合规范的融合式单文件笔记
- 严格执行架构硬约定（单文件小节结构、拓展 callout、Mermaid mindmap、移除自测题）
- 统计 `◉课堂`/`◉课件`/`◉教材` 来源标记计数
- 委托 NoteStore 写入落地与更新清单
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from sqlalchemy import select

from app.config import CONFIG_DIR, AppConfig, get_app_config
from app.core.ids import local_now
from app.core.note_markers import count_markers
from app.db.models import Course, Recording, Transcript
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.providers.base import LLMProvider, Message
from app.providers.registry import ProviderRegistry
from app.repositories.note_store import NoteMeta, NoteStore
from app.repositories.note_store_local import ObsidianNoteStore
from app.schemas.note import NoteDTO, NoteGenerateRequest

__all__ = ["NoteGenerationService"]

PROMPT_FILE: Path = CONFIG_DIR / "prompts" / "note_fused.md"


class NoteGenerationService:
    """融合式单文件笔记生成服务。"""

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
        llm_provider: LLMProvider | None = None,
        note_store: NoteStore | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()
        if llm_provider is not None:
            self.llm_provider = llm_provider
        else:
            self.llm_provider = ProviderRegistry(self.config).build_llm()
        if note_store is not None:
            self.note_store = note_store
        else:
            from app.deps import get_note_store

            self.note_store = get_note_store()

    def _load_prompt_template(self) -> str:
        if PROMPT_FILE.exists():
            return PROMPT_FILE.read_text(encoding="utf-8")
        return (
            "请根据以下课堂转写生成融合式单文件笔记，包含概述、知识架构Mindmap、核心知识点、"
            "老师强调、事务待办、勘误表、⚠️待确认、学习建议。绝对不要包含自测题。"
        )

    def _clean_markdown(self, text: str) -> str:
        """剥除首尾可能的代码块外壳。"""
        stripped = text.strip()
        if stripped.startswith("```markdown") and stripped.endswith("```"):
            stripped = stripped[len("```markdown") : -3].strip()
        elif stripped.startswith("```") and stripped.endswith("```"):
            stripped = stripped[3:-3].strip()
        return stripped

    def _remove_self_test_sections(self, markdown: str) -> str:
        """防御性过滤：移除任何可能残留的自测题小节（用户拍板要求删掉自测）。"""
        # 移除标题包含 自测 的二级或三级标题及后续自测内容，直至下一个标题
        pattern = r"(?:\n|^)##+[^\n]*自测[^\n]*\n.*?(?=\n##|\Z)"
        cleaned = re.sub(pattern, "", markdown, flags=re.DOTALL)
        return cleaned.strip()

    def _extract_mindmap(self, text: str) -> str | None:
        """提取 Mermaid mindmap 块。"""
        match = re.search(r"```mermaid\s*\n(mindmap.*?)```", text, flags=re.DOTALL)
        return match.group(1).strip() if match else None

    def _extract_todos(self, text: str) -> list[str]:
        """提取 - [ ] 待办列表。"""
        return re.findall(r"-\s*\[\s*\]\s*(.+)", text)

    def _extract_pending(self, text: str) -> list[str]:
        """提取 ⚠️待确认 列表。"""
        match = re.search(r"##\s*⚠️待确认\s*\n(.*?)(?=\n##|\Z)", text, flags=re.DOTALL)
        if not match:
            return []
        items = []
        for line in match.group(1).strip().splitlines():
            line_str = line.strip().lstrip("-*•0123456789. ")
            if line_str and "无遗留" not in line_str and "完整" not in line_str:
                items.append(line_str)
        return items

    async def generate_note(
        self,
        req: NoteGenerateRequest,
    ) -> tuple[NoteDTO, str, dict[str, int]]:
        """执行完整的笔记生成流程。"""
        # 1. 获取转写文本与勘误
        transcript_text = ""
        errata_list: list[dict[str, Any]] = []

        async with self.database.session_scope() as session:
            if req.transcript_id:
                stmt_t = select(Transcript).where(Transcript.id == req.transcript_id)
                res_t = await session.execute(stmt_t)
                tr_obj = res_t.scalar_one_or_none()
                if tr_obj:
                    transcript_text = tr_obj.corrected_text or tr_obj.raw_text
                    errata_list = tr_obj.errata or []
            elif req.recording_id:
                stmt_r = select(Transcript).where(Transcript.recording_id == req.recording_id)
                res_r = await session.execute(stmt_r)
                tr_obj = res_r.scalar_one_or_none()
                if tr_obj:
                    transcript_text = tr_obj.corrected_text or tr_obj.raw_text
                    errata_list = tr_obj.errata or []

        # 兜底：从物理转写文件读取
        if not transcript_text:
            try:
                from app.services.obsidian_service import ObsidianService

                obs_svc = ObsidianService(self.config)
                transcript_text = obs_svc.read_transcript(
                    req.course_name, req.lesson, req.class_date
                )
            except Exception:
                transcript_text = f"【课堂实录】{req.course_name} 第{req.lesson}次课 ({req.class_date})"

        # 2. 提取或确定主题
        topic = (req.topic or "").strip()
        if not topic:
            # 简洁提示提取主题（3-6个字，无日期前缀后缀）
            extract_msg = [
                Message(
                    role="system",
                    content="你负责为课堂笔记提取3~6个字的核心中文主题关键词。严禁包含日期、课程名或前后缀，仅输出关键词本身。",
                ),
                Message(
                    role="user",
                    content=f"课程：{req.course_name}\n转写片段：\n{transcript_text[:1500]}",
                ),
            ]
            try:
                raw_kw = await self.llm_provider.complete(extract_msg)
                topic = re.sub(r"[^\w\u4e00-\u9fa5]", "", raw_kw)[:12].strip()
            except Exception:
                topic = f"第{req.lesson}次课核心理论"
        if not topic:
            topic = f"第{req.lesson}次课"

        # 3. 组装生成提示词并调用 LLM
        prompt_tmpl = self._load_prompt_template()
        note_id = uuid.uuid4().hex
        created_str = local_now().strftime("%Y-%m-%d %H:%M:%S")
        origin_str = "cloud" if self.config.is_cloud else "win"

        system_prompt = prompt_tmpl.replace("{note_id}", note_id)
        system_prompt = system_prompt.replace("{course_name}", req.course_name)
        system_prompt = system_prompt.replace("{lesson}", str(req.lesson))
        system_prompt = system_prompt.replace("{topic}", topic)
        system_prompt = system_prompt.replace("{created_at}", created_str)
        system_prompt = system_prompt.replace("{origin}", origin_str)
        system_prompt = system_prompt.replace("{class_date}", req.class_date)

        user_content = (
            f"【课程名称】{req.course_name}\n"
            f"【课次序号】第 {req.lesson} 次课\n"
            f"【上课日期】{req.class_date}\n"
            f"【建议主题】{topic}\n"
            f"【已知勘误】\n{errata_list}\n\n"
            f"【课堂转写正文】\n{transcript_text}"
        )

        messages = [
            Message(role="system", content=system_prompt),
            Message(role="user", content=user_content),
        ]

        llm_response = await self.llm_provider.complete(messages)
        markdown = self._clean_markdown(llm_response)
        markdown = self._remove_self_test_sections(markdown)

        # 4. 提取结构要素并统计标记
        marker_stats = count_markers(markdown)
        mindmap = self._extract_mindmap(markdown)
        todos = self._extract_todos(markdown)
        pending = self._extract_pending(markdown)

        # 5. 调用 NoteStore 写入
        meta = await self.note_store.write(
            course_name=req.course_name,
            topic=topic,
            date_str=req.class_date,
            markdown=markdown,
            origin=origin_str,  # type: ignore
            note_id=note_id,
            lesson=req.lesson,
            transcript_id=req.transcript_id,
            mindmap=mindmap,
            todos=todos,
            pending=pending,
            marker_stats=marker_stats,
        )

        # 6. 构造返回 DTO
        dto = NoteDTO(
            id=f"note_{meta.note_id[:8]}",
            note_id=meta.note_id,
            course_name=req.course_name,
            lesson=req.lesson,
            topic=topic,
            format="融合式（课堂实录 + 拓展讲解）",
            obsidian_path=meta.rel_path,
            content_hash=meta.content_hash,
            origin=meta.origin,
            deleted=meta.deleted,
            marker_stats=marker_stats,
            created_at=meta.updated_at,
            updated_at=meta.updated_at,
        )

        return dto, markdown, marker_stats
