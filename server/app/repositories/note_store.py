"""NoteStore 端口定义（架构设计 §3.5，ADR-006）。

领域端口：屏蔽 Obsidian 本地目录 / 云端对象存储 / Android 本地库的底层读写差异。
业务服务只依赖 NoteStore，绝不直接拼文件系统路径或 open()。
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal, Protocol

from pydantic import BaseModel

__all__ = ["NoteMeta", "NoteStore", "NoteStoreCapabilities"]


class NoteMeta(BaseModel):
    """笔记元数据（跨端一致的逻辑快照）。"""

    note_id: str  # 稳定逻辑身份（uuid）
    rel_path: str  # 相对路径：课堂笔记/<课程>/<主题>_YYYY-MM-DD.md
    content_hash: str  # sha256(markdown 正文字节)
    updated_at: datetime  # 更新时间
    origin: Literal["win", "cloud", "android"] = "win"
    deleted: bool = False  # 软删除标记
    size: int | None = None


class NoteStoreCapabilities(BaseModel):
    """NoteStore 实现能力声明。"""

    stores_body: bool  # 本端是否持有正文
    is_authority: bool  # 是否为本端权威
    supports_offline_read: bool  # 是否支持离线只读


class NoteStore(Protocol):
    """NoteStore 端口协议。"""

    async def read(self, note_id: str) -> tuple[str, NoteMeta]:
        """按稳定 note_id 读取笔记 Markdown 正文与元数据。"""
        ...

    async def write(
        self,
        *,
        course_name: str,
        topic: str,
        date_str: str,
        markdown: str,
        origin: Literal["win", "cloud", "android"] = "win",
        note_id: str | None = None,
        lesson: int | None = None,
    ) -> NoteMeta:
        """写入笔记。适配器负责计算 sha256 哈希、物理落盘/存储、登记清单与同步元数据。"""
        ...

    async def list_meta(self, course_name: str | None = None) -> list[NoteMeta]:
        """列出指定课程（或全部）的笔记元数据清单。"""
        ...

    async def delete(
        self, note_id: str, origin: Literal["win", "cloud", "android"] = "win"
    ) -> NoteMeta:
        """软删除笔记，写入 tombstone。"""
        ...

    async def persist(
        self,
        note_id: str,
        markdown: str,
        *,
        rel_path: str | None = None,
    ) -> str:
        """按 note_id 持久化 Markdown 正文到物理存储，返回实际 rel_path。

        与 ``write`` 不同：``persist`` 不解析课程/主题/日期等元信息，
        仅负责「把内容写到磁盘/对象存储」——供同步推送链路使用。
        若 ``rel_path`` 未提供，实现应从 DB 查 ``Note.obsidian_path``，
        若仍为空则使用落盘暂存路径 ``_sync/<note_id>.md``。
        """
        ...

    async def read_stored(self, storage_key: str) -> str:
        """读取给定存储键的正文，供冲突副本裁决使用。"""
        ...

    async def exists(self, note_id: str) -> bool:
        """判断笔记是否存在且未删除。"""
        ...

    def capabilities(self) -> NoteStoreCapabilities:
        """声明适配器能力。"""
        ...
