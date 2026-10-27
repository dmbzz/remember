"""作业搜题服务（Service 层封装 · 架构设计 §1.2、T4-02）。"""

from __future__ import annotations

from sqlalchemy import select

from app.config import AppConfig, get_app_config
from app.db.models import Question, SolutionRecord
from app.db.session import Database, get_database
from app.errors import ApiError, ErrorCode
from app.pipelines.homework_pipeline import HomeworkPipeline
from app.schemas.homework import HomeworkSolveRequest, SolutionRecordDTO

__all__ = ["HomeworkService"]


class HomeworkService:
    """作业搜题与解题记录查询服务。"""

    def __init__(
        self,
        config: AppConfig | None = None,
        database: Database | None = None,
        pipeline: HomeworkPipeline | None = None,
    ) -> None:
        self.config = config or get_app_config()
        self.database = database or get_database()
        self.pipeline = pipeline or HomeworkPipeline(self.config, self.database)

    async def solve(self, req: HomeworkSolveRequest) -> SolutionRecordDTO:
        """执行搜题与解题比对。"""
        return await self.pipeline.solve(req)

    async def get_solution(self, solution_id: str) -> SolutionRecordDTO:
        """按 ID 查询历史解答记录。"""
        async with self.database.session_scope() as session:
            stmt = select(SolutionRecord, Question).join(
                Question, SolutionRecord.question_id == Question.id
            ).where(SolutionRecord.id == solution_id)
            res = await session.execute(stmt)
            row = res.first()
            if not row:
                raise ApiError(ErrorCode.NOT_FOUND, f"解答记录不存在：{solution_id}")

            sol, q = row
            return SolutionRecordDTO(
                id=sol.id,
                question_id=q.id,
                course=q.course,
                stem=q.stem_ocr,
                teacher_route=sol.teacher_route or {},
                ai_independent=sol.ai_independent or {},
                compare_result=sol.compare_result,
                conflict_reason=sol.conflict_reason,
                final_conclusion=sol.final_conclusion or "",
                cited_note_paths=sol.cited_note_paths or [],
                created_at=sol.created_at,
            )

    async def list_solutions(self, limit: int = 20) -> list[SolutionRecordDTO]:
        """查询最近的解答记录。"""
        async with self.database.session_scope() as session:
            stmt = (
                select(SolutionRecord, Question)
                .join(Question, SolutionRecord.question_id == Question.id)
                .order_by(SolutionRecord.created_at.desc())
                .limit(limit)
            )
            res = await session.execute(stmt)
            rows = res.all()
            return [
                SolutionRecordDTO(
                    id=sol.id,
                    question_id=q.id,
                    course=q.course,
                    stem=q.stem_ocr,
                    teacher_route=sol.teacher_route or {},
                    ai_independent=sol.ai_independent or {},
                    compare_result=sol.compare_result,
                    conflict_reason=sol.conflict_reason,
                    final_conclusion=sol.final_conclusion or "",
                    cited_note_paths=sol.cited_note_paths or [],
                    created_at=sol.created_at,
                )
                for sol, q in rows
            ]
