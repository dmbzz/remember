r"""Obsidian 归档与清单登记服务（架构设计 §1.2、§3.4，T2-03、T3-01）。

硬约定（不可变契约）：
    - 笔记归档：`课堂笔记\<课程名>\<主题>_YYYY-MM-DD.md`
    - 转写原文：`课堂笔记\转写原文\<课程名>_第N次课_YYYY-MM-DD.txt`
    - 登记清单：`课堂笔记\00-任务规划\已处理文件清单.md`
    - 命名规则：简洁关键词，无日期前缀、无后缀，日期放文件名末尾（ADR-002）
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from app.config import AppConfig, get_app_config
from app.core.ids import local_now

__all__ = ["ArchiveService"]


class ArchiveService:
    """归档与路径计算服务。"""

    def __init__(self, config: AppConfig | None = None) -> None:
        self.config = config or get_app_config()

    @property
    def obsidian_root(self) -> Path:
        """Obsidian 物理库根目录（动态读取配置）。"""
        return Path(self.config.obsidian_root)

    @property
    def notes_base_dir(self) -> Path:
        """课堂笔记主根目录。"""
        return self.obsidian_root / "课堂笔记"

    @property
    def transcript_dir(self) -> Path:
        """转写原文存放目录。"""
        return self.notes_base_dir / "转写原文"

    @property
    def tracking_file_path(self) -> Path:
        """已处理文件清单 Markdown 路径。"""
        return self.notes_base_dir / "00-任务规划" / "已处理文件清单.md"

    # -----------------------------------------------------------------------
    # 标准路径计算（契约）
    # -----------------------------------------------------------------------
    def transcript_filename(self, course_name: str, lesson: int, date_str: str) -> str:
        """计算转写文件名，形如：`工程力学_第1次课_2026-09-18.txt`。"""
        clean_course = course_name.replace("/", "_").replace("\\", "_").strip()
        return f"{clean_course}_第{lesson}次课_{date_str}.txt"

    def transcript_path(self, course_name: str, lesson: int, date_str: str) -> Path:
        """返回转写原文绝对路径。"""
        return self.transcript_dir / self.transcript_filename(course_name, lesson, date_str)

    def note_filename(self, topic: str, date_str: str) -> str:
        """计算笔记文件名：简洁关键词 + 末尾日期，无前缀无后缀（ADR-002）。"""
        clean_topic = topic.replace("/", "_").replace("\\", "_").strip()
        return f"{clean_topic}_{date_str}.md"

    def note_path(self, course_name: str, topic: str, date_str: str) -> Path:
        r"""返回笔记 Markdown 绝对路径：`课堂笔记\<课程名>\<主题>_YYYY-MM-DD.md`。"""
        clean_course = course_name.replace("/", "_").replace("\\", "_").strip()
        return self.notes_base_dir / clean_course / self.note_filename(topic, date_str)

    # -----------------------------------------------------------------------
    # 转写原文落盘与清单登记
    # -----------------------------------------------------------------------
    def save_transcript_file(
        self,
        course_name: str,
        lesson: int,
        date_str: str,
        content: str,
    ) -> Path:
        """将转写原文保存至 Obsidian 库的对应目录。"""
        target = self.transcript_path(course_name, lesson, date_str)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return target

    def register_processed(
        self,
        *,
        transcript_filename: str,
        course_name: str,
        class_date: str,
        note_name: str = "（待生成）",
    ) -> None:
        """在 `已处理文件清单.md` 追加登记一行。"""
        tracking_path = self.tracking_file_path
        tracking_path.parent.mkdir(parents=True, exist_ok=True)

        header = (
            "# 已处理文件清单\n\n"
            "| 转写文件名 | 课程 | 日期 | 处理时间 | 产出笔记 |\n"
            "|---|---|---|---|---|\n"
        )

        now_str = local_now().strftime("%Y-%m-%d %H:%M")
        row = f"| {transcript_filename} | {course_name} | {class_date} | {now_str} | {note_name} |\n"

        if not tracking_path.exists() or tracking_path.stat().st_size == 0:
            tracking_path.write_text(header + row, encoding="utf-8")
        else:
            existing = tracking_path.read_text(encoding="utf-8")
            if "| 转写文件名 |" not in existing:
                tracking_path.write_text(header + existing + "\n" + row, encoding="utf-8")
            else:
                # 检查是否已有同名转写文件记录，避免重复追加
                if transcript_filename in existing:
                    return
                if not existing.endswith("\n"):
                    existing += "\n"
                tracking_path.write_text(existing + row, encoding="utf-8")
