"""课堂笔记 API 端点测试。"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import AppConfig
from app.db.base import Base
from app.db.models import Course, Note
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_db, get_llm_provider, get_note_store
from app.main import create_app
from app.providers.base import LLMProvider, Message, ProviderCapabilities
from app.repositories.note_store_local import ObsidianNoteStore


class SimpleMockLLM(LLMProvider):
    def __init__(self, config: object = None):
        super().__init__(config or {}, "mock_llm")

    async def complete(self, messages: list[Message], **kwargs) -> str:
        if any("核心中文主题关键词" in (m.content or "") for m in messages):
            return "动态电路暂态分析"
        return (
            "# 动态电路暂态分析（2026-09-18）\n\n"
            "## 概述\n讲授一阶RC电路零输入与零状态响应。\n\n"
            "## 知识架构（Mindmap）\n```mermaid\nmindmap\n  root((暂态))\n    一阶\n```\n\n"
            "## 核心知识点\n### 三要素法 ◉课堂\n计算初始值与稳态值。\n\n"
            "> [!tip] 💡 拓展｜三要素公式\n> - **为什么**：微分方程特解。\n> - **怎么用**：套公式。\n> - **陷阱**：时间常数单位。\n\n"
            "## 老师强调\n期中必考！\n\n"
            "## 事务待办\n- [ ] 习题4-1\n\n"
            "## 勘误表\n| 误 | 正 | 故 |\n|---|---|---|\n\n"
            "## ⚠️待确认\n无\n\n"
            "## 学习建议\n建议多画响应曲线。\n"
        )

    async def complete_structured(self, messages: list[Message], schema, **kwargs):
        raise NotImplementedError

    def count_tokens(self, text: str) -> int:
        return len(text)

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(name="mock", kind="llm", runs_offline=True, incurs_cost=False)


@pytest.fixture
async def client_env(tmp_path: Path):
    vault = tmp_path / "ApiVault"
    vault.mkdir()

    db_file = tmp_path / "test_api.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)
    db = Database(db_url)
    config = AppConfig(obsidian_root=str(vault))
    note_store = ObsidianNoteStore(config=config, database=db)
    mock_llm = SimpleMockLLM()

    # 预置课程
    async with session_factory() as session:
        c = Course(id="crs_circuit", name="电路原理", semester="2026-秋", teacher="李老师")
        session.add(c)
        await session.commit()

    app = create_app()

    async def override_get_db():
        async with session_factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_config] = lambda: config
    app.dependency_overrides[get_database_dep] = lambda: db
    app.dependency_overrides[get_llm_provider] = lambda: mock_llm
    app.dependency_overrides[get_note_store] = lambda: note_store

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c, vault

    await engine.dispose()


@pytest.mark.asyncio
async def test_notes_api_full_flow(client_env):
    client, vault = client_env

    # 1. 生成笔记
    gen_resp = await client.post(
        "/api/notes/generate",
        json={
            "course_name": "电路原理",
            "lesson": 1,
            "class_date": "2026-09-18",
            "topic": "动态电路暂态分析",
        },
    )
    assert gen_resp.status_code == 200
    gen_data = gen_resp.json()["data"]
    note_id = gen_data["note"]["note_id"]
    db_id = gen_data["note"]["id"]
    assert "动态电路暂态分析" in gen_data["markdown"]
    assert "自测" not in gen_data["markdown"]

    # 2. 列出笔记
    list_resp = await client.get("/api/notes?course=电路原理")
    assert list_resp.status_code == 200
    list_data = list_resp.json()["data"]
    assert list_data["total"] >= 1
    assert any(n["note_id"] == note_id for n in list_data["items"])

    # 3. 读取单篇元数据
    meta_resp = await client.get(f"/api/notes/{note_id}")
    assert meta_resp.status_code == 200
    assert meta_resp.json()["data"]["topic"] == "动态电路暂态分析"

    # 4. 读取全文内容
    content_resp = await client.get(f"/api/notes/{note_id}/content")
    assert content_resp.status_code == 200
    assert "三要素公式" in content_resp.json()["data"]["markdown"]

    # 5. 软删除
    del_resp = await client.delete(f"/api/notes/{note_id}")
    assert del_resp.status_code == 200
    assert del_resp.json()["data"]["deleted"] is True

    # 6. 删除后在列表中不展现
    list_resp2 = await client.get("/api/notes")
    assert list_resp2.status_code == 200
    assert not any(n["note_id"] == note_id for n in list_resp2.json()["data"]["items"])


@pytest.mark.asyncio
async def test_existing_vault_notes_with_legacy_database(tmp_path: Path):
    vault = tmp_path / "vault"
    course_dir = vault / "课堂笔记" / "工程力学"
    course_dir.mkdir(parents=True)
    (course_dir / "受力图_2026-09-01.md").write_text("# 受力图\n正文", encoding="utf-8")
    metadata_dir = vault / "课堂笔记" / "00-任务规划"
    metadata_dir.mkdir()
    (metadata_dir / "清单.md").write_text("不显示", encoding="utf-8")

    db_url = f"sqlite+aiosqlite:///{tmp_path / 'legacy.db'}"
    engine = create_async_engine(db_url)
    async with engine.begin() as conn:
        await conn.exec_driver_sql("CREATE TABLE notes (id TEXT PRIMARY KEY, course_id TEXT)")
    factory = async_sessionmaker(engine, expire_on_commit=False)
    config = AppConfig(obsidian_root=str(vault), db_url=db_url)
    app = create_app()

    async def override_get_db():
        async with factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_config] = lambda: config
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        listed = await client.get("/api/notes")
        assert listed.status_code == 200
        data = listed.json()["data"]
        assert data["total"] == 1
        note = data["items"][0]
        assert note["topic"] == "受力图"
        assert note["course_name"] == "工程力学"
        assert note["class_date"] == "2026-09-01"
        content = await client.get(f"/api/notes/{note['note_id']}/content")
        assert content.status_code == 200
        assert content.json()["data"]["markdown"] == "# 受力图\n正文"
        filtered = await client.get("/api/notes?course=线性代数")
        assert filtered.json()["data"]["total"] == 0
    await engine.dispose()
