"""作业搜题流水线（Pipelines · 架构设计 §1.2、T4-02，ADR-004）。

核心契约（不可变约定）：
- 老师路线优先：优先跟老师课上方法与符号体系（检索笔记驱动）
- AI 独立解仅作校验
- 产生冲突时必须给出唯一确定结论，【严禁并列两种都对】（硬规则 #8）
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Any

from app.config import AppConfig, get_app_config
from app.db.models import Question, SolutionRecord
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.providers.base import LLMProvider, Message, VisionProvider
from app.providers.registry import ProviderRegistry
from app.schemas.homework import HomeworkSolveRequest, SolutionRecordDTO
from app.services.index_service import IndexService

__all__ = ["HomeworkPipeline"]


class HomeworkPipeline:
    """作业搜题与双路线交叉比对流水线。"""

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
        llm_provider: LLMProvider | None = None,
        vision_provider: VisionProvider | None = None,
        index_service: IndexService | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()
        registry = ProviderRegistry(self.config)
        self.llm_provider = llm_provider or registry.build_llm()
        self.vision_provider = vision_provider or registry.build_vision()
        self.index_service = index_service or IndexService(self.config, self.database)

    async def _extract_stem(self, req: HomeworkSolveRequest) -> str:
        """从文字或图片中提取题干。"""
        if req.stem and req.stem.strip():
            return req.stem.strip()

        if req.image_path:
            # 视觉识别图片
            prompt = (
                "请精准识别并完整提取图片中的题目文本、已知条件、物理量符号与数学公式。"
                "行内公式用 $...$，整行公式用 $$...$$。仅输出题干内容本身。"
            )
            return await self.vision_provider.read_image(req.image_path, prompt)

        raise ApiError(ErrorCode.VALIDATION_ERROR, "请提供题目题干文本或图片")

    async def _solve_teacher_route(
        self,
        stem: str,
        notes_context: str,
        course: str | None,
    ) -> dict[str, Any]:
        """按老师课堂讲法与笔记求解题目。"""
        system_prompt = (
            "你是一位严谨的工科作业辅导专家。请【严格优先根据提供的老师课堂笔记与讲法】，"
            "采用老师课上讲授的方法、符号体系与解题套路求解该题目。\n"
            "必须输出 JSON 格式：\n"
            "{\n"
            '  "method_name": "方法名称（如：动能定理法 / 传递函数梅逊公式）",\n'
            '  "steps": ["步骤1：...", "步骤2：...", "步骤3：..."],\n'
            '  "conclusion": "最终简练明确的结论与数值答案",\n'
            '  "analysis": "依据老师课上强调的解题逻辑说明"\n'
            "}"
        )
        user_content = (
            f"【题目内容】\n{stem}\n\n"
            f"【所属课程】{course or '工科核心课'}\n\n"
            f"【老师课堂笔记与强调要点】\n{notes_context}"
        )
        messages = [
            Message(role="system", content=system_prompt),
            Message(role="user", content=user_content),
        ]
        raw = await self.llm_provider.complete(messages)
        return self._parse_json_result(
            raw,
            default_method="老师课上推荐解法",
            default_conclusion="参见分步推导",
        )

    async def _solve_ai_independent(self, stem: str, course: str | None) -> dict[str, Any]:
        """AI 不参考笔记独立求解作校验。"""
        system_prompt = (
            "你是一位顶尖学术专家。请【不要参考任何外部讲法，纯粹以学科第一性原理与通用定理】独立求解此题。\n"
            "必须输出 JSON 格式：\n"
            "{\n"
            '  "method_name": "独立解法名称",\n'
            '  "steps": ["步骤1：...", "步骤2：..."],\n'
            '  "conclusion": "独立求解的最终明确结论与数值答案",\n'
            '  "analysis": "第一性原理依据说明"\n'
            "}"
        )
        user_content = f"【题目内容】\n{stem}\n【学科】{course or '综合'}"
        messages = [
            Message(role="system", content=system_prompt),
            Message(role="user", content=user_content),
        ]
        raw = await self.llm_provider.complete(messages)
        return self._parse_json_result(
            raw,
            default_method="通用定理独立解",
            default_conclusion="参见分步推导",
        )

    async def _reconcile_routes(
        self,
        stem: str,
        teacher: dict[str, Any],
        ai: dict[str, Any],
    ) -> tuple[str, str | None, str]:
        """交叉比对两路线结果；冲突时深挖原因并给出唯一结论（严禁两种都对，ADR-004）。"""
        t_ans = str(teacher.get("conclusion", "")).strip()
        a_ans = str(ai.get("conclusion", "")).strip()

        # 快速一致性比对
        if t_ans == a_ans or (len(t_ans) > 2 and t_ans in a_ans):
            return "一致", None, t_ans

        # 调度仲裁：以老师路线为首要标准，分析冲突成因并定案
        system_prompt = (
            "你负责作业辅导的双路线交叉仲裁。\n"
            "【核心硬规则】作业辅导以老师路线优先（符合校内批改标准）；"
            "两路线结果出现分歧时，必须深入剖析深层成因（如符号定义正方向不同、基准面选择差异、"
            "近似条件取舍、或计算笔误），并给出【唯一确定的最终结论】！\n"
            "【绝对红线】严禁模棱两可、严禁和稀泥、严禁给出「两种都对」的并列结论！\n"
            "输出格式（严格 JSON）：\n"
            "{\n"
            '  "is_consistent": false,\n'
            '  "conflict_reason": "冲突深层原因分析...",\n'
            '  "final_conclusion": "唯一判定的最终结论（以老师路线与批改标准为准）"\n'
            "}"
        )
        user_content = (
            f"【题目】{stem}\n\n"
            f"【老师路线（优先标准）】\n方法：{teacher.get('method_name')}\n结论：{t_ans}\n\n"
            f"【AI独立解（辅助校验）】\n方法：{ai.get('method_name')}\n结论：{a_ans}"
        )
        messages = [
            Message(role="system", content=system_prompt),
            Message(role="user", content=user_content),
        ]
        raw = await self.llm_provider.complete(messages)
        parsed = self._parse_json_result(
            raw,
            default_method="",
            default_conclusion=t_ans or a_ans,
        )

        is_consistent = parsed.get("is_consistent", False)
        if is_consistent:
            return "一致", None, t_ans or a_ans

        conflict_reason = parsed.get(
            "conflict_reason",
            "两路线在物理量正方向或方程基准选择上存在符号差异，按课上老师统一规范为准。",
        )
        final_conclusion = parsed.get("final_conclusion", t_ans)

        # 终极防御过滤：若 LLM 依然包含"两种都对"的措辞，强制清洗
        if "两种都对" in final_conclusion or "两个答案都可以" in final_conclusion:
            final_conclusion = f"按老师课上批改标准判定，唯一结论为：{t_ans}"

        return "冲突", conflict_reason, final_conclusion

    def _parse_json_result(
        self,
        text: str,
        default_method: str,
        default_conclusion: str,
    ) -> dict[str, Any]:
        """安全从模型输出中抽取并解析 JSON。"""
        clean = text.strip()
        if "```json" in clean:
            clean = clean.split("```json", 1)[1].split("```", 1)[0].strip()
        elif "```" in clean:
            clean = clean.split("```", 1)[1].split("```", 1)[0].strip()

        try:
            loaded = json.loads(clean)
            if isinstance(loaded, dict):
                return loaded
        except Exception:
            pass

        return {
            "method_name": default_method,
            "steps": [text.strip()[:300]],
            "conclusion": default_conclusion,
            "analysis": "直接解析文本输出",
        }

    async def solve(self, req: HomeworkSolveRequest) -> SolutionRecordDTO:
        """执行完整的作业搜题与交叉比对流程。"""
        # 1. 识别题干
        stem = await self._extract_stem(req)

        # 2. 检索老师路线笔记
        search_results = await self.index_service.search(
            query=stem,
            course_name=req.course,
            limit=3,
        )
        cited_paths = [r.rel_path for r in search_results]
        notes_context = "\n\n".join(
            f"【文件：{r.rel_path}】\n{r.snippet}" for r in search_results
        ) or "（未检索到直接相关的专属笔记，请根据该课程学科经典讲法解答）"

        # 3. 老师路线优先求解
        teacher_solution = await self._solve_teacher_route(stem, notes_context, req.course)

        # 4. AI 独立解求解
        ai_solution = await self._solve_ai_independent(stem, req.course)

        # 5. 交叉比对（严格禁止两种都对）
        compare_res, conflict_reason, final_conclusion = await self._reconcile_routes(
            stem, teacher_solution, ai_solution
        )

        # 6. 持久化记录
        now_dt = datetime.now(timezone.utc)
        async with self.database.session_scope() as session:
            q_obj = Question(
                source="photo" if req.image_path or req.image_base64 else "upload",
                course=req.course,
                stem_ocr=stem,
                created_at=now_dt,
            )
            session.add(q_obj)
            await session.flush()

            sol_obj = SolutionRecord(
                question_id=q_obj.id,
                teacher_route=teacher_solution,
                ai_independent=ai_solution,
                compare_result=compare_res,
                conflict_reason=conflict_reason,
                final_conclusion=final_conclusion,
                cited_note_paths=cited_paths,
                created_at=now_dt,
            )
            session.add(sol_obj)
            await session.flush()

            return SolutionRecordDTO(
                id=sol_obj.id,
                question_id=q_obj.id,
                course=req.course,
                stem=stem,
                teacher_route=teacher_solution,
                ai_independent=ai_solution,
                compare_result=compare_res,
                conflict_reason=conflict_reason,
                final_conclusion=final_conclusion,
                cited_note_paths=cited_paths,
                created_at=now_dt,
            )
