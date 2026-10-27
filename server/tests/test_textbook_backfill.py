"""测试教材换算引擎、缺页强制报错、教材回填流水线与 API 端点。"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import AppConfig
from app.db.base import Base
from app.db.models import Course, Note
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_db, get_note_store
from app.errors import ApiError, ErrorCode
from app.main import create_app
from app.pipelines.backfill_pipeline import BackfillPipeline
from app.repositories.note_store_local import ObsidianNoteStore
from app.schemas.textbook import TextbookIndexEntryDTO
from app.services.textbook_service import TextbookPageMapper, TextbookService


def test_linear_algebra_page_mapping():
    """测试线性代数分段两档换算与缺页 120 报错（架构设计 §7.7 / §8.1）。"""
    mapper = TextbookPageMapper

    # 第一档：printed_page <= 119 → idx = printed_page + 9
    assert mapper.printed_page_to_idx("线性代数", 1) == 10
    assert mapper.printed_page_to_idx("线性代数", 100) == 109
    assert mapper.printed_page_to_idx("线性代数", 119) == 128
    assert mapper.idx_to_printed_page("线性代数", 128) == 119

    # 缺页 120：必须报错，严禁静默取相邻页
    with pytest.raises(ApiError) as exc_info:
        mapper.printed_page_to_idx("线性代数", 120)
    assert exc_info.value.code == ErrorCode.NOT_FOUND
    assert "缺印刷页 120" in exc_info.value.message

    # 第二档：printed_page >= 121 → idx = printed_page + 8
    assert mapper.printed_page_to_idx("线性代数", 121) == 129
    assert mapper.idx_to_printed_page("线性代数", 129) == 121
    assert mapper.printed_page_to_idx("线性代数", 200) == 208


def test_engineering_mechanics_page_mapping():
    """测试工程力学分段两档换算与缺页 72、73 报错（架构设计 §7.7 / §8.1）。"""
    mapper = TextbookPageMapper

    # 第一档：printed_page <= 71 → idx = printed_page + 16
    assert mapper.printed_page_to_idx("工程力学", 1) == 17
    assert mapper.printed_page_to_idx("工程力学", 71) == 87
    assert mapper.idx_to_printed_page("工程力学", 87) == 71

    # 缺页 72、73：必须报错
    with pytest.raises(ApiError) as exc_72:
        mapper.printed_page_to_idx("工程力学", 72)
    assert exc_72.value.code == ErrorCode.NOT_FOUND
    assert "缺印刷页 72" in exc_72.value.message

    with pytest.raises(ApiError) as exc_73:
        mapper.printed_page_to_idx("工程力学", 73)
    assert exc_73.value.code == ErrorCode.NOT_FOUND
    assert "缺印刷页 73" in exc_73.value.message

    # 第二档：printed_page >= 74 → idx = printed_page + 14
    assert mapper.printed_page_to_idx("工程力学", 74) == 88
    assert mapper.idx_to_printed_page("工程力学", 88) == 74
    assert mapper.printed_page_to_idx("工程力学", 100) == 114


@pytest.fixture
async def backfill_env(tmp_path: Path):
    vault = tmp_path / "BackfillVault"
    vault.mkdir()

    db_file = tmp_path / "test_backfill.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    db = Database(db_url)
    config = AppConfig(obsidian_root=str(vault))
    note_store = ObsidianNoteStore(config=config, database=db)
    tb_svc = TextbookService(config, db)

    yield note_store, tb_svc, db, vault
    await engine.dispose()


@pytest.mark.asyncio
async def test_backfill_pipeline_success_and_preservation(backfill_env):
    """测试教材回填：确有内容时补充并打标 ◉教材；无内容时坚决保留 ⚠️待确认，严禁臆造。"""
    note_store, tb_svc, db, vault = backfill_env

    initial_note = (
        "---\n"
        "note_id: test-bf-note\n"
        "course: 自动控制原理\n"
        "---\n\n"
        "# 稳定性理论（2026-09-18）\n\n"
        "## 核心知识点\n"
        "### 劳斯判据 ◉课堂\n特征方程各阶系数为正。\n\n"
        "## ⚠️待确认\n"
        "- 辅助多项式求导后的根与原方程根的对应关系需再核对教材 P112\n"
        "- 老师提到的拓展自适应控制算法课件未详述\n\n"
        "## 学习建议\n认真复习。\n"
    )

    await note_store.write(
        course_name="自动控制原理",
        topic="稳定性理论",
        date_str="2026-09-18",
        markdown=initial_note,
        note_id="test-bf-note",
    )

    # 模拟教材服务：P112 命中，自适应算法未命中
    async def mock_get_page_text(course_name: str, page: int) -> str:
        if page == 112:
            return "辅助多项式导数根代表了特征多项式在虚轴上的对称共轭极点分布。"
        return ""

    tb_svc.get_page_text = mock_get_page_text

    pipeline = BackfillPipeline(
        note_store=note_store,
        textbook_service=tb_svc,
    )

    backfilled, stats, updated = await pipeline.run(
        note_id="test-bf-note",
        course_name="自动控制原理",
    )

    assert updated is True
    assert len(backfilled) == 1
    assert "P112" in backfilled[0]
    assert stats["textbook"] >= 1

    # 验证更新后的 Markdown 正文
    updated_md, _ = await note_store.read("test-bf-note")

    # 1. 验证教材回填 callout 插入
    assert "> [!note] 📖 教材回填补充｜P112 ◉教材" in updated_md
    assert "共轭极点分布" in updated_md

    # 2. 验证已确认条目被打勾标明
    assert "（已由教材回填证实 ◉教材）" in updated_md

    # 3. ★ 硬约束验证：未找到教材依据的要点坚决保留，不臆造
    assert "老师提到的拓展自适应控制算法课件未详述" in updated_md


@pytest.mark.asyncio
async def test_textbooks_api_index_and_backfill(backfill_env):
    """测试教材索引录入、查询与 API 触发回填。"""
    note_store, tb_svc, db, vault = backfill_env

    # 预置一篇笔记
    initial_note = (
        "# 矩阵运算（2026-09-18）\n\n"
        "## 核心知识点\n矩阵乘法 ◉课堂。\n\n"
        "## ⚠️待确认\n- 矩阵乘法结合律的证明需参考 P25\n\n"
        "## 学习建议\n多练运算。\n"
    )
    await note_store.write(
        course_name="线性代数",
        topic="矩阵运算",
        date_str="2026-09-18",
        markdown=initial_note,
        note_id="matrix-note",
    )

    # 预置教材服务返回
    tb_svc.get_page_text = AsyncMock(return_value="矩阵乘法满足结合律 (AB)C = A(BC)。")

    app = create_app()
    app.dependency_overrides[get_config] = lambda: tb_svc.config
    app.dependency_overrides[get_database_dep] = lambda: db
    app.dependency_overrides[get_note_store] = lambda: note_store

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # 1. 录入索引
        idx_resp = await client.post(
            "/api/textbooks/index",
            json={
                "course_name": "线性代数",
                "example_no": "例 2.1",
                "summary": "矩阵乘法计算示例",
                "printed_page": 25,
                "knowledge_point": "矩阵乘法",
                "in_scope": True,
            },
        )
        assert idx_resp.status_code == 200
        assert idx_resp.json()["data"]["printed_page"] == 25

        # 2. 查询索引
        query_resp = await client.get("/api/textbooks/index?course=线性代数&kp=矩阵")
        assert query_resp.status_code == 200
        assert len(query_resp.json()["data"]) >= 1

        # 3. 触发教材回填
        with patch.object(BackfillPipeline, "__init__", lambda self, *args, **kwargs: None):
            with patch.object(
                BackfillPipeline,
                "run",
                AsyncMock(return_value=(["P25: 结合律"], {"classroom": 1, "textbook": 1}, True)),
            ):
                bf_resp = await client.post(
                    "/api/textbooks/backfill",
                    json={"note_id": "matrix-note", "course_name": "线性代数"},
                )
                assert bf_resp.status_code == 200
                data = bf_resp.json()["data"]
                assert data["updated"] is True
                assert data["marker_stats"]["textbook"] == 1
