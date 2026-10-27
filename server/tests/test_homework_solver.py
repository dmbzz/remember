"""作业搜题与双路线交叉校验测试（T4-02、ADR-004，硬规则 #8 严禁两种都对）。"""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import AppConfig
from app.db.base import Base
from app.db.models import Question, SolutionRecord
from app.db.session import Database
from app.deps import get_config, get_database_dep, get_db, get_llm_provider, get_vision_provider
from app.main import create_app
from app.pipelines.homework_pipeline import HomeworkPipeline
from app.providers.base import LLMProvider, Message, ProviderCapabilities, VisionProvider
from app.schemas.homework import HomeworkSolveRequest
from app.services.homework_service import HomeworkService
from app.services.index_service import IndexService
from app.services.obsidian_service import ObsidianService


class MockHomeworkLLM(LLMProvider):
    def __init__(self, mode: str = "consistent"):
        super().__init__({}, "mock_hw_llm")
        self.mode = mode

    async def complete(self, messages: list[Message], **kwargs) -> str:
        prompt_text = " ".join(m.content or "" for m in messages)

        # 1. 仲裁请求
        if "交叉仲裁" in prompt_text:
            if self.mode == "conflict_bad_llm":
                # 模拟 LLM 试图输出和稀泥的"两种都对"
                return json.dumps({
                    "is_consistent": False,
                    "conflict_reason": "正方向选取不同导致正负号差异",
                    "final_conclusion": "两种都对，看各自的坐标系定义",
                }, ensure_ascii=False)
            elif self.mode == "conflict":
                return json.dumps({
                    "is_consistent": False,
                    "conflict_reason": "符号定义正方向不同，老师统一规定顺时针为正",
                    "final_conclusion": "顺时针方向 12 N·m",
                }, ensure_ascii=False)
            else:
                return json.dumps({
                    "is_consistent": True,
                    "conflict_reason": None,
                    "final_conclusion": "5伏特 (5V)",
                }, ensure_ascii=False)

        # 2. 老师路线求解
        if "老师课堂笔记与讲法" in prompt_text or "老师课堂笔记与强调要点" in prompt_text:
            if "conflict" in self.mode:
                return json.dumps({
                    "method_name": "老师动能定理解法",
                    "steps": ["按顺时针为正列动能方程", "积分得转矩"],
                    "conclusion": "顺时针方向 12 N·m",
                    "analysis": "课上强调顺时针定标",
                }, ensure_ascii=False)
            return json.dumps({
                "method_name": "三要素法",
                "steps": ["求初值 u(0+)=0", "求稳态值 u(inf)=5V", "套公式"],
                "conclusion": "5伏特 (5V)",
                "analysis": "课上强调的典型一阶响应",
            }, ensure_ascii=False)

        # 3. AI 独立解求解
        if "独立求解" in prompt_text:
            if "conflict" in self.mode:
                return json.dumps({
                    "method_name": "拉氏变换独立解",
                    "steps": ["建逆时针标系", "算得负值"],
                    "conclusion": "逆时针方向 -12 N·m",
                    "analysis": "以逆时针为正向",
                }, ensure_ascii=False)
            return json.dumps({
                "method_name": "微分方程时域经典法",
                "steps": ["列微分方程", "通解加特解"],
                "conclusion": "5伏特 (5V)",
                "analysis": "标准一阶电路求解",
            }, ensure_ascii=False)

        return "{}"

    async def complete_structured(self, messages: list[Message], schema, **kwargs):
        raise NotImplementedError

    def count_tokens(self, text: str) -> int:
        return len(text)

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(name="mock_hw", kind="llm", runs_offline=True, incurs_cost=False)


class MockHomeworkVision(VisionProvider):
    def __init__(self):
        super().__init__({}, "mock_hw_vision")

    async def read_image(self, image_path: str, prompt: str) -> str:
        return "求图示电路中开关合上后的电容电压响应 u_c(t)。"

    async def read_pages(self, pdf_path: str, pages: list[int], prompt: str) -> list[str]:
        return ["页文本内容"] * len(pages)

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(name="mock_vis", kind="vision", runs_offline=True, incurs_cost=False)


@pytest.fixture
async def homework_env(tmp_path: Path):
    vault = tmp_path / "HwVault"
    vault.mkdir()

    # 预置一篇课堂笔记
    note_dir = vault / "课堂笔记" / "电路原理"
    note_dir.mkdir(parents=True, exist_ok=True)
    (note_dir / "暂态分析_2026-09-18.md").write_text(
        "# 暂态分析\n## 核心知识点\n### 三要素法 ◉课堂\n\n## 老师强调\n开关动作前后电容电压连续！",
        encoding="utf-8",
    )

    db_file = tmp_path / "test_hw.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"
    engine = create_async_engine(db_url, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(bind=engine, expire_on_commit=False)
    db = Database(db_url)
    config = AppConfig(obsidian_root=str(vault))
    obs_svc = ObsidianService(config)
    idx_svc = IndexService(config, db, obs_svc)
    await idx_svc.rebuild_index()

    llm_consistent = MockHomeworkLLM(mode="consistent")
    vision = MockHomeworkVision()

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
    app.dependency_overrides[get_llm_provider] = lambda: llm_consistent
    app.dependency_overrides[get_vision_provider] = lambda: vision

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield {
            "client": client,
            "vault": vault,
            "db": db,
            "config": config,
            "idx_svc": idx_svc,
            "vision": vision,
            "llm_consistent": llm_consistent,
            "app": app,
        }

    await engine.dispose()


@pytest.mark.asyncio
async def test_homework_pipeline_consistent(homework_env):
    """测试一致情况下的求解流水线。"""
    config = homework_env["config"]
    db = homework_env["db"]
    llm = homework_env["llm_consistent"]
    vision = homework_env["vision"]
    idx_svc = homework_env["idx_svc"]

    pipe = HomeworkPipeline(
        config=config,
        database=db,
        llm_provider=llm,
        vision_provider=vision,
        index_service=idx_svc,
    )

    req = HomeworkSolveRequest(
        course="电路原理",
        stem="求一阶电路暂态响应电容电压",
    )
    result = await pipe.solve(req)

    assert result.stem == "求一阶电路暂态响应电容电压"
    assert result.compare_result == "一致"
    assert result.final_conclusion == "5伏特 (5V)"
    assert result.conflict_reason is None
    assert result.teacher_route["method_name"] == "三要素法"
    assert result.ai_independent["method_name"] == "微分方程时域经典法"


@pytest.mark.asyncio
async def test_homework_pipeline_conflict_and_forbid_two_correct(homework_env):
    """测试分歧情况：严格执行 ADR-004 与硬规则 #8，禁止出现「两种都对」，给出唯一结论。"""
    config = homework_env["config"]
    db = homework_env["db"]
    vision = homework_env["vision"]
    idx_svc = homework_env["idx_svc"]

    # 1. 普通冲突情况
    llm_conflict = MockHomeworkLLM(mode="conflict")
    pipe1 = HomeworkPipeline(
        config=config,
        database=db,
        llm_provider=llm_conflict,
        vision_provider=vision,
        index_service=idx_svc,
    )

    req1 = HomeworkSolveRequest(course="理论力学", stem="求刚体转动所受力矩")
    res1 = await pipe1.solve(req1)

    assert res1.compare_result == "冲突"
    assert "正方向" in res1.conflict_reason
    assert res1.final_conclusion == "顺时针方向 12 N·m"
    assert "两种都对" not in res1.final_conclusion

    # 2. 模拟 LLM 仲裁时和稀泥输出「两种都对」，测试系统防御性清洗机制
    llm_bad = MockHomeworkLLM(mode="conflict_bad_llm")
    pipe2 = HomeworkPipeline(
        config=config,
        database=db,
        llm_provider=llm_bad,
        vision_provider=vision,
        index_service=idx_svc,
    )

    res2 = await pipe2.solve(req1)
    assert res2.compare_result == "冲突"
    # 验证红线：绝对不能包含「两种都对」
    assert "两种都对" not in res2.final_conclusion
    assert "唯一结论" in res2.final_conclusion or "顺时针方向 12 N·m" in res2.final_conclusion


@pytest.mark.asyncio
async def test_homework_api_endpoints(homework_env):
    """用户取消搜题后，旧接口不再对客户端开放。"""
    client: AsyncClient = homework_env["client"]
    assert (await client.post("/api/homework/solve", json={"stem": "test"})).status_code == 404
    assert (await client.get("/api/homework")).status_code == 404
