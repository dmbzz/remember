"""Deleting a referenced course must preserve its learning material and schedule."""

import pytest

from test_asr_upload import env
from app.db.models import (
    Course,
    Courseware,
    Note,
    ScheduleEntry,
    TextbookIndexEntry,
    TextbookPage,
)


@pytest.mark.parametrize(
    "model,values,path_field",
    [
        (Note, {"topic": "保留的课堂笔记"}, "obsidian_path"),
        (Courseware, {"type": "pdf"}, "file_path"),
        (TextbookPage, {"book_name": "测试教材", "printed_page": 12}, "render_path"),
        (TextbookIndexEntry, {"example_no": "例 1.2", "summary": "保留的教材索引"}, None),
    ],
    ids=["note", "courseware", "textbook-page", "textbook-index"],
)
async def test_referenced_course_delete_preserves_material_and_schedule(
    env, tmp_path, model, values, path_field
):
    client, db, _, _, course_id = env
    material_file = tmp_path / "existing-material.dat"
    material_file.write_bytes(b"ORIGINAL LEARNING MATERIAL")
    fields = dict(values)
    if path_field:
        fields[path_field] = str(material_file)

    async with db.session_scope() as session:
        reference = model(course_id=course_id, **fields)
        schedule = ScheduleEntry(course_id=course_id, weekday=1, period=1)
        session.add_all([reference, schedule])
        await session.flush()
        reference_id, schedule_id = reference.id, schedule.id

    response = await client.delete(f"/api/courses/{course_id}")
    assert response.status_code == 409, response.text
    assert "已有数据已保留" in response.json()["message"]
    async with db.session_scope() as session:
        assert await session.get(Course, course_id) is not None
        stored = await session.get(model, reference_id)
        assert stored is not None and stored.course_id == course_id
        for name, value in fields.items():
            assert getattr(stored, name) == value
        assert await session.get(ScheduleEntry, schedule_id) is not None
    assert material_file.read_bytes() == b"ORIGINAL LEARNING MATERIAL"
