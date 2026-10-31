"""接口层路由汇总（统一前缀 ``/api``，架构设计 §3.4）。"""

from fastapi import APIRouter

from app.api import (
    courses,
    handoff,
    health,
    notes,
    profile,
    recordings,
    schedule,
    search,
    settings,
    sync,
    textbooks,
    transcription,
    usage,
    app_update,
    pairing,
    asr,
    asr_models,
)

__all__ = ["api_router"]

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(pairing.router)
api_router.include_router(settings.router)
api_router.include_router(handoff.router)
api_router.include_router(courses.router)
api_router.include_router(profile.router)
api_router.include_router(schedule.router)
api_router.include_router(recordings.router)
api_router.include_router(asr.router)
api_router.include_router(asr_models.router)
api_router.include_router(transcription.router)
api_router.include_router(notes.router)
api_router.include_router(textbooks.router)
api_router.include_router(search.router)
api_router.include_router(sync.router)
api_router.include_router(usage.router)
api_router.include_router(app_update.router)
