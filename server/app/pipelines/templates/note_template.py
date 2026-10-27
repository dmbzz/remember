"""融合式单文件笔记模板与格式化规范（ADR-001，自测已删除）。"""

from __future__ import annotations

from typing import Any

__all__ = ["render_note_frontmatter", "FUSED_NOTE_SECTIONS"]

FUSED_NOTE_SECTIONS: tuple[str, ...] = (
    "frontmatter",
    "title",
    "overview",
    "mindmap",
    "key_points",
    "teacher_emphasis",
    "todos",
    "errata",
    "pending_confirmation",
    "study_recommendations",
)


def render_note_frontmatter(
    *,
    note_id: str,
    course_name: str,
    lesson: int,
    topic: str,
    created_at: str,
    origin: str = "win",
) -> str:
    """渲染合规的 YAML Frontmatter。"""
    return (
        "---\n"
        f"note_id: {note_id}\n"
        f"course: {course_name}\n"
        f"lesson: {lesson}\n"
        f"topic: {topic}\n"
        f"created: {created_at}\n"
        "format: 融合式（课堂实录 + 拓展讲解）\n"
        f"origin: {origin}\n"
        f"tags: [课堂笔记, {course_name}]\n"
        "---\n"
    )
