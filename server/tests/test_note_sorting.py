"""笔记按标题/文件名时间排序专项测试。"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import AppConfig
from app.core.note_sorting import extract_date_from_text, sort_notes_by_title_time
from app.db.base import Base
from app.deps import get_config, get_db
from app.main import create_app
from app.schemas.note import NoteDTO


def test_extract_date_from_text_supports_common_formats_and_rejects_invalid():
    assert extract_date_from_text("圆轴扭转_2026-11-24")[1] == "2026-11-24"
    assert extract_date_from_text("2026-09-05_周报")[1] == "2026-09-05"
    assert extract_date_from_text("实验报告_2026.10.14")[1] == "2026-10-14"
    assert extract_date_from_text("2026年9月1日 力学导论")[1] == "2026-09-01"
    assert extract_date_from_text("20261015 线性代数")[1] == "2026-10-15"
    dt, iso = extract_date_from_text("复盘 2026-10-14 14:30")
    assert iso == "2026-10-14"
    assert (dt.hour, dt.minute) == (14, 30)

    # 非法日期数字不被误判为时间
    assert extract_date_from_text("编号_2026-02-30") is None
    assert extract_date_from_text("第20269999章") is None
    assert extract_date_from_text("普通物理1作业清单") is None


def test_sort_notes_ignores_mtime_and_keeps_undated_last():
    old_date_recently_edited = NoteDTO(
        id="1",
        note_id="n1",
        course_name="工程力学",
        topic="受力图",
        class_date="2026-09-01",
        created_at=datetime(2026, 11, 25, tzinfo=timezone.utc),
        updated_at=datetime(2026, 11, 25, tzinfo=timezone.utc),
    )
    new_date_earlier_edited = NoteDTO(
        id="2",
        note_id="n2",
        course_name="工程力学",
        topic="圆轴扭转",
        class_date="2026-11-24",
        created_at=datetime(2026, 11, 24, tzinfo=timezone.utc),
        updated_at=datetime(2026, 11, 24, tzinfo=timezone.utc),
    )
    mid_date_from_topic = NoteDTO(
        id="3",
        note_id="n3",
        course_name="线性代数",
        topic="2026年10月15日 向量空间",
        class_date=None,
        created_at=datetime(2026, 10, 15, tzinfo=timezone.utc),
        updated_at=datetime(2026, 10, 15, tzinfo=timezone.utc),
    )
    undated = NoteDTO(
        id="4",
        note_id="n4",
        course_name="普通物理1",
        topic="普通物理1作业清单",
        class_date=None,
        created_at=datetime(2026, 11, 25, 23, tzinfo=timezone.utc),
        updated_at=datetime(2026, 11, 25, 23, tzinfo=timezone.utc),
    )

    desc = sort_notes_by_title_time(
        [old_date_recently_edited, undated, mid_date_from_topic, new_date_earlier_edited],
        descending=True,
    )
    assert [n.note_id for n in desc] == ["n2", "n3", "n1", "n4"]

    asc = sort_notes_by_title_time(
        [old_date_recently_edited, undated, mid_date_from_topic, new_date_earlier_edited],
        descending=False,
    )
    assert [n.note_id for n in asc] == ["n1", "n3", "n2", "n4"]


@pytest.mark.asyncio
async def test_api_notes_sorts_by_title_date_desc_and_asc(tmp_path: Path):
    vault = tmp_path / "vault"
    course_dir = vault / "课堂笔记" / "工程力学"
    course_dir.mkdir(parents=True)

    f_old = course_dir / "工程力学导论_2026-09-01.md"
    f_mid = course_dir / "2026年10月19日_剪力与弯矩.md"
    f_new = course_dir / "圆轴扭转_2026-11-24.md"
    f_undated = course_dir / "工程力学总复习清单.md"

    for f in (f_new, f_mid, f_old, f_undated):
        f.write_text("# 正文", encoding="utf-8")

    # 故意把最早课程与无日期文件的修改时间调到最新，验证排序不受 mtime 干扰
    os.utime(f_new, (1_700_000_100, 1_700_000_100))
    os.utime(f_mid, (1_700_000_200, 1_700_000_200))
    os.utime(f_old, (1_800_000_000, 1_800_000_000))
    os.utime(f_undated, (1_900_000_000, 1_900_000_000))

    db_url = f"sqlite+aiosqlite:///{tmp_path / 'sort.db'}"
    engine = create_async_engine(db_url)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    config = AppConfig(obsidian_root=str(vault), db_url=db_url)
    app = create_app()

    async def override_get_db():
        async with factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_config] = lambda: config

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp_desc = await client.get("/api/notes")
        assert resp_desc.status_code == 200
        topics_desc = [item["topic"] for item in resp_desc.json()["data"]["items"]]
        assert topics_desc == [
            "圆轴扭转",
            "2026年10月19日_剪力与弯矩",
            "工程力学导论",
            "工程力学总复习清单",
        ]

        resp_asc = await client.get("/api/notes?order=asc")
        assert resp_asc.status_code == 200
        topics_asc = [item["topic"] for item in resp_asc.json()["data"]["items"]]
        assert topics_asc == [
            "工程力学导论",
            "2026年10月19日_剪力与弯矩",
            "圆轴扭转",
            "工程力学总复习清单",
        ]
    await engine.dispose()
