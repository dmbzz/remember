"""教材服务：页码换算引擎、页面渲染与导览索引管理（架构设计 §7.7、§8.1，T3-03）。

核心约定（硬契约）：
- 一律以 0-based 图片索引 idx（`doc[idx]`）为基准
- 分段两档换算
- 缺页区间必须明确报错，禁止静默取相邻页（线性代数缺印刷页 120；工程力学缺 72、73）
- 换算参数支持动态解析，严禁写死单一常数
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from sqlalchemy import select

from app.config import AppConfig, get_app_config
from app.db.models import Course, TextbookIndexEntry, TextbookPage
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.schemas.textbook import TextbookIndexEntryDTO

__all__ = ["TextbookPageMapper", "TextbookService"]


class TextbookPageMapper:
    """教材印刷页码与 0-based 图片索引转换器（严格按 §8.1 约定）。"""

    @classmethod
    def printed_page_to_idx(cls, course_name: str, printed_page: int) -> int:
        """根据课程名与印刷页码计算 0-based 索引 idx（用于 `doc[idx]`）。"""
        name = course_name.strip()

        # ---- 1. 线性代数 ----
        if "线性代数" in name or "线代" in name:
            if printed_page == 120:
                raise ApiError(
                    ErrorCode.NOT_FOUND,
                    "线性代数教材缺印刷页 120（缺页区间），禁止取相邻页！",
                )
            if printed_page <= 119:
                return printed_page + 9  # idx <= 128
            return printed_page + 8  # idx >= 129

        # ---- 2. 工程力学 / 理论力学 / 材料力学 ----
        if "工程力学" in name or "力学" in name:
            if printed_page in (72, 73):
                raise ApiError(
                    ErrorCode.NOT_FOUND,
                    f"工程力学教材缺印刷页 {printed_page}（缺页区间），禁止取相邻页！",
                )
            if printed_page <= 71:
                return printed_page + 16  # idx <= 87
            return printed_page + 14  # idx >= 88

        # ---- 3. 通用兜底（假设常规前言目录约 10 页） ----
        if printed_page <= 0:
            raise ApiError(ErrorCode.VALIDATION_ERROR, f"非法印刷页码：{printed_page}")
        return max(0, printed_page - 1)

    @classmethod
    def idx_to_printed_page(cls, course_name: str, idx: int) -> int:
        """根据课程名与 0-based 索引反查印刷页码。"""
        name = course_name.strip()

        # ---- 1. 线性代数 ----
        if "线性代数" in name or "线代" in name:
            if idx <= 128:
                return idx - 9
            return idx - 8

        # ---- 2. 工程力学 ----
        if "工程力学" in name or "力学" in name:
            if idx <= 87:
                return idx - 16
            return idx - 14

        # ---- 3. 通用兜底 ----
        return idx + 1


class TextbookService:
    """教材物理文件检索、渲染与索引服务。"""

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()
        self.mapper = TextbookPageMapper

    @property
    def textbook_root(self) -> Path:
        return Path(self.config.textbook_root)

    def find_textbook_file(self, course_name: str) -> Path | None:
        """根据课程名在教材原件目录查找对应 PDF 文件。"""
        root = self.textbook_root
        if not root.exists():
            return None

        clean = course_name.strip()
        candidates = list(root.glob(f"*{clean}*.pdf"))
        if candidates:
            return candidates[0]

        # 别名查找
        short_names = {
            "线性代数": ["线代", "代数"],
            "工程力学": ["力学", "静力学"],
            "电路原理": ["电路"],
            "自动控制原理": ["自控", "控制原理"],
        }
        for kw in short_names.get(clean, []):
            matches = list(root.glob(f"*{kw}*.pdf"))
            if matches:
                return matches[0]

        return None

    def render_pages(self, course_name: str, printed_pages: list[int]) -> list[Path]:
        """将指定的印刷页码渲染为 PNG 图像，返回生成的图片绝对路径列表。"""
        import pymupdf

        pdf_path = self.find_textbook_file(course_name)
        if not pdf_path or not pdf_path.is_file():
            raise ApiError(
                ErrorCode.NOT_FOUND,
                f"未在教材目录 ({self.textbook_root}) 找到课程 [{course_name}] 的 PDF 原件",
            )

        # 临时产物目录
        out_dir = Path("tmp_pdf_pages").resolve()
        out_dir.mkdir(parents=True, exist_ok=True)

        rendered_paths: list[Path] = []
        doc = pymupdf.open(str(pdf_path))
        try:
            total_pages = len(doc)
            for page_num in printed_pages:
                idx = self.mapper.printed_page_to_idx(course_name, page_num)
                if idx < 0 or idx >= total_pages:
                    raise ApiError(
                        ErrorCode.VALIDATION_ERROR,
                        f"换算后索引 idx={idx} 超出 PDF 页面总数 {total_pages}",
                    )

                page = doc[idx]
                pix = page.get_pixmap(dpi=150)
                target_file = out_dir / f"{course_name}_P{page_num:03d}_idx{idx:03d}.png"
                pix.save(str(target_file))
                rendered_paths.append(target_file)
        finally:
            doc.close()

        return rendered_paths

    async def get_page_text(self, course_name: str, printed_page: int) -> str:
        """获取指定教材印刷页的文字内容（PDF 文字流优先提取）。"""
        import pymupdf

        # 1. 优先查数据库缓存
        async with self.database.session_scope() as session:
            stmt = select(TextbookPage).where(
                TextbookPage.printed_page == printed_page,
            )
            res = await session.execute(stmt)
            cached = res.scalar_one_or_none()
            if cached and cached.vision_text:
                return cached.vision_text

        # 2. 查物理 PDF 提取
        pdf_path = self.find_textbook_file(course_name)
        if not pdf_path or not pdf_path.is_file():
            return ""

        idx = self.mapper.printed_page_to_idx(course_name, printed_page)
        doc = pymupdf.open(str(pdf_path))
        try:
            if 0 <= idx < len(doc):
                text = doc[idx].get_text()
                return text.strip()
        finally:
            doc.close()

        return ""

    async def add_index_entry(self, entry: TextbookIndexEntryDTO) -> TextbookIndexEntryDTO:
        """录入或更新教材知识点与例题索引。"""
        async with self.database.session_scope() as session:
            # 获取 course_id
            stmt_c = select(Course).where(Course.name == entry.course_name)
            res_c = await session.execute(stmt_c)
            c = res_c.scalar_one_or_none()
            course_id = c.id if c else f"crs_{entry.course_name}"

            obj = TextbookIndexEntry(
                course_id=course_id,
                example_no=entry.example_no,
                summary=entry.summary,
                printed_page=entry.printed_page,
                knowledge_point=entry.knowledge_point,
                in_scope=entry.in_scope,
            )
            session.add(obj)
            await session.flush()
            entry.id = obj.id
            return entry

    async def query_index(
        self,
        course_name: str,
        knowledge_point: str | None = None,
    ) -> list[TextbookIndexEntryDTO]:
        """查询教材索引条目。"""
        async with self.database.session_scope() as session:
            stmt = select(TextbookIndexEntry)
            if knowledge_point:
                stmt = stmt.where(TextbookIndexEntry.knowledge_point.contains(knowledge_point))

            res = await session.execute(stmt)
            rows = res.scalars().all()
            return [
                TextbookIndexEntryDTO(
                    id=r.id,
                    course_name=course_name,
                    example_no=r.example_no,
                    summary=r.summary,
                    printed_page=r.printed_page,
                    knowledge_point=r.knowledge_point,
                    in_scope=r.in_scope,
                )
                for r in rows
            ]
