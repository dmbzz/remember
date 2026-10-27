"""Obsidian 目录读写与交互服务（架构设计 §1.2、§3.4，T2-03、T3-01）。

封装对本地 Obsidian 库文件的物理读写操作，与 ArchiveService 协同：
- 转写原文存取与归档
- 笔记 Markdown 文件的读写与枚举
- 保持纯文本与 Frontmatter 结构完整
"""

from __future__ import annotations

import os
from pathlib import Path
from app.config import AppConfig, get_app_config
from app.errors import ApiError, ErrorCode
from app.schemas.obsidian import ObsidianPathStatusDTO
from app.services.archive_service import ArchiveService

__all__ = ["ObsidianService"]


class ObsidianService:
    """Obsidian 物理库读写服务。"""

    def __init__(self, config: AppConfig | None = None) -> None:
        self.config = config or get_app_config()
        self.archive_service = ArchiveService(self.config)

    @property
    def obsidian_root(self) -> Path:
        """动态获取当前配置的 Obsidian 库根目录。"""
        return Path(self.config.obsidian_root)

    def _resolve(self, rel_path: str) -> Path:
        """安全解析相对路径，防止目录穿越。"""
        clean = rel_path.lstrip("/\\").replace("\\", "/")
        target = (self.obsidian_root / clean).resolve()
        root_resolved = self.obsidian_root.resolve()
        if root_resolved != target and root_resolved not in target.parents:
            raise ApiError(ErrorCode.VALIDATION_ERROR, f"非法 Obsidian 相对路径：{rel_path}")
        return target

    def exists(self, rel_path: str) -> bool:
        """判断 Obsidian 库中某文件是否存在。"""
        return self._resolve(rel_path).is_file()

    def read_text(self, rel_path: str) -> str:
        """读取指定相对路径的文本内容。"""
        target = self._resolve(rel_path)
        if not target.is_file():
            raise ApiError(ErrorCode.NOT_FOUND, f"Obsidian 文件不存在：{rel_path}")
        return target.read_text(encoding="utf-8")

    def write_text(self, rel_path: str, content: str) -> Path:
        """写入指定相对路径的文本内容（自动创建父目录）。"""
        target = self._resolve(rel_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return target

    def read_transcript(self, course_name: str, lesson: int, date_str: str) -> str:
        """读取转写原文。"""
        target = self.archive_service.transcript_path(course_name, lesson, date_str)
        if not target.is_file():
            raise ApiError(ErrorCode.NOT_FOUND, f"转写原文文件不存在：{target.name}")
        return target.read_text(encoding="utf-8")

    def write_transcript(
        self, course_name: str, lesson: int, date_str: str, text: str
    ) -> Path:
        """写入转写原文并登记清单。"""
        saved = self.archive_service.save_transcript_file(
            course_name, lesson, date_str, text
        )
        self.archive_service.register_processed(
            transcript_filename=saved.name,
            course_name=course_name,
            class_date=date_str,
        )
        return saved

    def list_notes(self, course_name: str | None = None) -> list[str]:
        """列出指定课程或全部课程的 Markdown 笔记相对路径。"""
        base_dir = self.archive_service.notes_base_dir
        if course_name:
            base_dir = base_dir / course_name.strip()

        if not base_dir.exists():
            return []

        rel_paths = []
        for file in sorted(base_dir.rglob("*.md")):
            # 排除 00-任务规划 等元数据目录
            if "00-" in file.parts:
                continue
            rel_paths.append(file.relative_to(self.obsidian_root).as_posix())
        return rel_paths

    def inspect_vault(self, path: Path | str | None = None) -> ObsidianPathStatusDTO:
        """检查并诊断指定路径（或当前库）的健康度与目录结构。"""
        raw = str(path).strip().strip("'\"") if path else str(self.obsidian_root).strip().strip("'\"")
        target = Path(raw).resolve()
        status = ObsidianPathStatusDTO(path=str(target), obsidian_root=str(target))
        try:
            if not target.exists():
                return status
            status.exists = True
            if not target.is_dir():
                return status
            status.is_dir = True
            status.is_directory = True

            # 检查写权限
            test_file = target / f".cna_perm_test_{os.getpid()}"
            try:
                test_file.write_text("ok", encoding="utf-8")
                test_file.unlink()
                status.is_writable = True
                status.writable = True
            except Exception:
                status.is_writable = False
                status.writable = False

            # 结构检查
            obsidian_dir = target / ".obsidian"
            notes_dir = target / "课堂笔记"
            transcripts_dir = notes_dir / "转写原文"
            task_planning_dir = notes_dir / "00-任务规划"
            tracking_file = task_planning_dir / "已处理文件清单.md"

            status.has_obsidian_dir = obsidian_dir.is_dir()
            status.has_notes_dir = notes_dir.is_dir()
            status.has_transcripts_dir = transcripts_dir.is_dir()
            status.has_task_planning_dir = task_planning_dir.is_dir()
            status.has_tracking_file = tracking_file.is_file()

            is_full = (
                status.has_notes_dir
                and status.has_transcripts_dir
                and status.has_task_planning_dir
                and status.has_tracking_file
            )
            status.is_fully_initialized = is_full
            status.skeleton_initialized = is_full
        except Exception as exc:
            status.error = str(exc)
        return status

    def init_vault(self, path: Path | str | None = None) -> tuple[list[str], list[str]]:
        """初始化目标目录为符合 ClassNotes 规范的 Obsidian 库骨架。

        创建：
            - `课堂笔记/`
            - `课堂笔记/转写原文/`
            - `课堂笔记/00-任务规划/`
            - `课堂笔记/00-任务规划/已处理文件清单.md`（带标准表头）

        返回:
            (created_dirs, initialized_files)
        """
        raw = str(path).strip().strip("'\"") if path else str(self.obsidian_root).strip().strip("'\"")
        target = Path(raw).resolve()
        created_dirs: list[str] = []
        initialized_files: list[str] = []

        if not target.exists():
            target.mkdir(parents=True, exist_ok=True)
            created_dirs.append(str(target))

        notes_dir = target / "课堂笔记"
        transcripts_dir = notes_dir / "转写原文"
        task_planning_dir = notes_dir / "00-任务规划"
        tracking_file = task_planning_dir / "已处理文件清单.md"

        for d in (notes_dir, transcripts_dir, task_planning_dir):
            if not d.exists():
                d.mkdir(parents=True, exist_ok=True)
                created_dirs.append(str(d))

        if not tracking_file.exists() or tracking_file.stat().st_size == 0:
            header = (
                "# 已处理文件清单\n\n"
                "| 转写文件名 | 课程 | 日期 | 处理时间 | 产出笔记 |\n"
                "|---|---|---|---|---|\n"
            )
            tracking_file.write_text(header, encoding="utf-8")
            initialized_files.append(str(tracking_file))

        return created_dirs, initialized_files

