"""检索索引与全文搜索测试（架构设计 §1.2、§3.4，T4-01）。"""

from __future__ import annotations

from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import AppConfig
from app.db.base import Base
from app.db.models import SearchIndex
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_db
from app.main import create_app
from app.services.index_service import IndexService
from app.services.obsidian_service import ObsidianService


SAMPLE_NOTE_1 = """---
course: 电路原理
topic: 暂态三要素法
lesson: 4
date: 2026-09-18
---

# 暂态三要素法（2026-09-18）

## 概述
讲解一阶RC与RL电路的三要素计算。

## 知识架构（Mindmap）
```mermaid
mindmap
  root((暂态))
    三要素
```

## 核心知识点
### 1. 初始值与稳态值 ◉课堂
换路定则是求解初始值的核心。

### 2. 时间常数求解 ◉课件
戴维南等效电阻法求Req。

> [!tip] 💡 拓展｜等效电容法
> - **为什么**：便于多电容合并。

## 老师强调
期末必考含受控源的戴维南等效电阻，换路定则严禁代入t等于无穷！

## 事务待办
- [ ] 课后习题

## 勘误表
| 误 | 正 | 故 |
|---|---|---|

## ⚠️待确认
无

## 学习建议
掌握微积分公式对应关系。
"""

SAMPLE_NOTE_2 = """---
course: 理论力学
topic: 动量矩定理
lesson: 6
date: 2026-09-19
---

# 动量矩定理（2026-09-19）

## 概述
质点系相对于定点和质心的动量矩定理。

## 核心知识点
### 1. 动量矩的计算 ◉课堂
对定轴转动刚体，动量矩等于转动惯量乘角速度。

## 老师强调
注意质心参考系与定系的区别，惯性力矩不可漏！
"""


@pytest.fixture
async def search_env(tmp_path: Path):
    vault = tmp_path / "SearchVault"
    vault.mkdir()

    # 创建示例笔记文件
    note1_path = vault / "课堂笔记" / "电路原理" / "暂态三要素法_2026-09-18.md"
    note1_path.parent.mkdir(parents=True, exist_ok=True)
    note1_path.write_text(SAMPLE_NOTE_1, encoding="utf-8")

    note2_path = vault / "课堂笔记" / "理论力学" / "动量矩定理_2026-09-19.md"
    note2_path.parent.mkdir(parents=True, exist_ok=True)
    note2_path.write_text(SAMPLE_NOTE_2, encoding="utf-8")

    db_file = tmp_path / "test_search.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)
    db = Database(db_url)
    config = AppConfig(obsidian_root=str(vault))
    obs_service = ObsidianService(config)
    index_service = IndexService(config, db, obs_service)

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

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield {
            "client": client,
            "vault": vault,
            "index_service": index_service,
            "db": db,
            "note1_rel": "课堂笔记/电路原理/暂态三要素法_2026-09-18.md",
            "note2_rel": "课堂笔记/理论力学/动量矩定理_2026-09-19.md",
        }

    await engine.dispose()


@pytest.mark.asyncio
async def test_index_and_search_service(search_env):
    idx_svc: IndexService = search_env["index_service"]
    db: Database = search_env["db"]
    note1_rel = search_env["note1_rel"]
    note2_rel = search_env["note2_rel"]

    # 1. 建立单篇索引
    ok1 = await idx_svc.index_note_file(note1_rel)
    ok2 = await idx_svc.index_note_file(note2_rel)
    assert ok1 is True
    assert ok2 is True

    # 验证数据库只存索引元数据，不存全文（PRD §7）
    async with db.session_scope() as session:
        res = await session.execute(select(SearchIndex))
        rows = res.scalars().all()
        assert len(rows) == 2
        for r in rows:
            assert hasattr(r, "keywords")
            assert hasattr(r, "tokens")
            assert "概述" not in (r.tokens or "")  # 没把正文全塞进去

    # 2. 搜索测试：搜索老师强调中的重点
    results = await idx_svc.search("受控源 戴维南等效电阻")
    assert len(results) >= 1
    assert results[0].rel_path == note1_rel
    assert "老师强调" in results[0].snippet
    assert "换路定则" in results[0].snippet or "戴维南" in results[0].snippet

    # 3. 按课程过滤搜索
    mech_results = await idx_svc.search("动量矩", course_name="理论力学")
    assert len(mech_results) == 1
    assert mech_results[0].rel_path == note2_rel

    # 4. 一致性检查
    report = await idx_svc.verify_consistency()
    assert report.total_indexed == 2
    assert report.valid_count == 2
    assert report.missing_count == 0

    # 模拟删除物理文件
    vault = search_env["vault"]
    (vault / note2_rel).unlink()
    report2 = await idx_svc.verify_consistency()
    assert report2.missing_count == 1
    assert note2_rel in report2.missing_files

    # 5. 全量重建
    indexed, removed = await idx_svc.rebuild_index()
    assert indexed == 1  # 删掉的 note2 不会被再次建立
    assert removed == 0


@pytest.mark.asyncio
async def test_search_api_endpoints(search_env):
    client: AsyncClient = search_env["client"]
    idx_svc: IndexService = search_env["index_service"]
    note1_rel = search_env["note1_rel"]

    await idx_svc.index_note_file(note1_rel)

    # 1. API: /api/search
    resp = await client.get("/api/search?q=三要素")
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert len(data) >= 1
    assert data[0]["title"] == "暂态三要素法_2026-09-18"

    # 2. API: /api/index/verify
    verify_resp = await client.get("/api/index/verify")
    assert verify_resp.status_code == 200
    v_data = verify_resp.json()["data"]
    assert v_data["total_indexed"] >= 1
    assert v_data["missing_count"] == 0

    # 3. API: /api/index/rebuild
    rebuild_resp = await client.post("/api/index/rebuild")
    assert rebuild_resp.status_code == 200
    r_data = rebuild_resp.json()["data"]
    assert "indexed" in r_data
