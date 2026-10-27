"""笔记与转写检索索引服务（架构设计 §1.2、§3.4，T4-01）。

注意：
- 服务端 SearchIndex 表【不存正文】（维持 PRD §7 约定），仅存路径、关键词、tokens 与一致性状态。
- 负责检索老师在课堂笔记中的讲法、例题与重点，为作业搜题提供优先路线。
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from sqlalchemy import delete, select

from app.config import AppConfig, get_app_config
from app.db.models import Course, Note, SearchIndex
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.schemas.search import ConsistencyReport, SearchResultItem
from app.services.obsidian_service import ObsidianService

__all__ = ["IndexService"]


class IndexService:
    """笔记检索与索引管理服务。"""

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
        obsidian_service: ObsidianService | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()
        self.obsidian_service = obsidian_service or ObsidianService(self.config)

    def _extract_keywords(self, content: str) -> list[str]:
        """从笔记 Markdown 中提取关键词与核心小节词汇。"""
        keywords: set[str] = set()

        # 1. 提取三级标题（知识点）
        headings = re.findall(r"^###\s*\d*\.?\s*(.+)$", content, flags=re.MULTILINE)
        for h in headings:
            clean_h = re.sub(r"[^\w\u4e00-\u9fa5]", "", h)
            if len(clean_h) >= 2:
                keywords.add(clean_h[:20])

        # 2. 提取老师强调小节
        emp_match = re.search(r"##\s*老师强调\s*\n(.*?)(?=\n##|\Z)", content, flags=re.DOTALL)
        if emp_match:
            words = re.findall(r"[\u4e00-\u9fa5]{2,6}", emp_match.group(1))
            for w in words:
                keywords.add(w)

        # 3. 提取拓展 callout 标题
        callout_titles = re.findall(r"> \[!tip\] 💡 拓展｜([^\n]+)", content)
        for ct in callout_titles:
            clean_ct = re.sub(r"[^\w\u4e00-\u9fa5]", "", ct)
            if clean_ct:
                keywords.add(clean_ct[:20])

        return list(keywords)

    async def index_note_file(self, rel_path: str) -> bool:
        """为单篇笔记建立或更新检索索引（不存正文）。"""
        if not self.obsidian_service.exists(rel_path):
            return False

        content = self.obsidian_service.read_text(rel_path)
        keywords = self._extract_keywords(content)
        tokens = " ".join(keywords) + " " + rel_path

        now_dt = datetime.now(timezone.utc)
        async with self.database.session_scope() as session:
            stmt = select(SearchIndex).where(SearchIndex.rel_path == rel_path)
            res = await session.execute(stmt)
            idx_obj = res.scalar_one_or_none()
            if idx_obj:
                idx_obj.keywords = keywords
                idx_obj.tokens = tokens
                idx_obj.consistency_status = "ok"
                idx_obj.updated_at = now_dt
            else:
                idx_obj = SearchIndex(
                    target_type="note",
                    rel_path=rel_path,
                    keywords=keywords,
                    tokens=tokens,
                    consistency_status="ok",
                    updated_at=now_dt,
                )
                session.add(idx_obj)
        return True

    async def rebuild_index(self) -> tuple[int, int]:
        """全量重建索引，返回 (indexed_count, removed_count)。"""
        rel_paths = self.obsidian_service.list_notes()
        indexed_count = 0

        async with self.database.session_scope() as session:
            await session.execute(delete(SearchIndex))

        for p in rel_paths:
            ok = await self.index_note_file(p)
            if ok:
                indexed_count += 1

        return indexed_count, 0

    async def search(
        self,
        query: str,
        course_name: str | None = None,
        limit: int = 10,
    ) -> list[SearchResultItem]:
        """检索与 query 相关的笔记，返回排序后的结果与上下文摘要（优先包含老师强调）。"""
        clean_q = query.strip()
        if not clean_q:
            return []

        # 提取 query 中的词汇片段
        q_tokens = re.findall(r"[\w\u4e00-\u9fa5]+", clean_q)
        if not q_tokens:
            q_tokens = [clean_q]

        async with self.database.session_scope() as session:
            stmt = select(SearchIndex).where(SearchIndex.consistency_status != "missing")
            if course_name:
                stmt = stmt.where(SearchIndex.rel_path.contains(course_name))

            res = await session.execute(stmt)
            indices = res.scalars().all()

        results: list[SearchResultItem] = []
        for idx in indices:
            score = 0.0
            tokens_str = idx.tokens or ""
            kw_list = idx.keywords or []

            # 计算匹配分值
            for tok in q_tokens:
                if tok in tokens_str:
                    score += 1.0
                for kw in kw_list:
                    if tok in kw or kw in tok:
                        score += 2.0

            # 路径中包含课程名或主题加分
            for tok in q_tokens:
                if tok in idx.rel_path:
                    score += 3.0

            if score <= 0.0:
                continue

            # 读取真实文件截取 snippet
            snippet = ""
            title = Path(idx.rel_path).stem
            if self.obsidian_service.exists(idx.rel_path):
                raw_text = self.obsidian_service.read_text(idx.rel_path)
                # 优先提取老师强调小节
                emp = re.search(r"##\s*老师强调\s*\n(.*?)(?=\n##|\Z)", raw_text, flags=re.DOTALL)
                if emp:
                    snippet = f"【老师强调】{emp.group(1).strip()[:150]}"
                else:
                    # 提取正文相关片段
                    snippet = raw_text[:200].replace("\n", " ").strip()

            results.append(
                SearchResultItem(
                    rel_path=idx.rel_path,
                    title=title,
                    snippet=snippet,
                    score=score,
                    target_type=idx.target_type,
                )
            )

        results.sort(key=lambda x: x.score, reverse=True)
        return results[:limit]

    async def verify_consistency(self) -> ConsistencyReport:
        """检查已索引的文件在 Obsidian 物理目录中是否存在。"""
        async with self.database.session_scope() as session:
            stmt = select(SearchIndex)
            res = await session.execute(stmt)
            all_indices = res.scalars().all()

            valid_count = 0
            missing_count = 0
            missing_files: list[str] = []

            for item in all_indices:
                if self.obsidian_service.exists(item.rel_path):
                    valid_count += 1
                    item.consistency_status = "ok"
                else:
                    missing_count += 1
                    missing_files.append(item.rel_path)
                    item.consistency_status = "missing"

            return ConsistencyReport(
                total_indexed=len(all_indices),
                valid_count=valid_count,
                missing_count=missing_count,
                missing_files=missing_files,
            )
