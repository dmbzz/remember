"""FastAPI 应用组装与运行入口。

职责（架构设计 §2.1）：
    - 组装 FastAPI、挂中间件与路由、生命周期（启动任务队列 / 初始化 DB）。

运行方式：
    cd server && python -m app.main                # 默认读 config/config.local.yaml
    CNA_CONFIG_FILE=config/config.cloud.yaml python -m app.main   # 云端模式

硬约定：业务代码不得 import 具体 Provider 实现类；实例化只发生在 app/deps.py。
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from fastapi import FastAPI

from app.api import api_router
from app.config import get_app_config
from app.core.security import AuthMiddleware, LanPairingMiddleware
from app.db.session import get_database
from app.deps import get_task_queue
from app.errors import register_exception_handlers
from app.logging_setup import RequestIdMiddleware, get_logger, setup_logging
from app.services.asr_jobs import AsrDispatcher
from app.services.pairing_discovery import PairingDiscovery
from app.services.pairing_service import PairingService
from app.services.upload_progress import UploadProgressMiddleware

__all__ = ["create_app", "app"]


def _mask_db_url(db_url: str) -> str:
    """对数据库连接串中的密码做脱敏，避免写入日志。"""
    if "@" in db_url and "://" in db_url:
        scheme, _, rest = db_url.partition("://")
        creds, _, host = rest.rpartition("@")
        if ":" in creds:
            user, _, _pwd = creds.partition(":")
            return f"{scheme}://{user}:***@{host}"
    return db_url


@asynccontextmanager
async def lifespan(application: FastAPI):
    """应用生命周期：启动时初始化日志/DB/任务队列，退出时优雅释放资源。"""
    config = get_app_config()
    log = get_logger("app.main")
    log.info(
        "app_starting",
        mode=config.deployment_mode,
        version=config.version,
        auth_enabled=config.auth_enabled,
    )

    # 初始化数据库。M0 阶段云端库可能尚未开通（D-07 用 create_all），
    # 失败时降级为告警而非阻断启动，保证 /api/health 在两种形态下均可用。
    database = get_database()
    db_ready = False
    try:
        await database.create_all()
        db_ready = True
        log.info("db_initialized", db_url=_mask_db_url(config.db_url))
    except Exception as exc:  # noqa: BLE001 - 启动期宽捕获，降级不崩溃
        log.warning("db_init_failed", error=str(exc), db_url=_mask_db_url(config.db_url))

    # 启动任务队列（进程内 asyncio 单 Worker）
    queue = get_task_queue()
    await queue.start()
    log.info("task_queue_started", worker=queue.worker_count)
    dispatcher = AsrDispatcher(database)
    application.state.asr_dispatcher = dispatcher
    if db_ready:
        await dispatcher.start()

    discovery = getattr(application.state, "pairing_discovery", None)
    if discovery is not None:
        if await discovery.start():
            log.info("pairing_discovery_started", port=config.pairing_discovery_port)
        else:
            log.warning("pairing_discovery_bind_failed", port=config.pairing_discovery_port)

    try:
        yield
    finally:
        if discovery is not None:
            await discovery.stop()
        from app.services.asr_model_manager import stop_model_operations
        from starlette.concurrency import run_in_threadpool
        await run_in_threadpool(stop_model_operations)
        await dispatcher.stop()
        await queue.stop()
        await database.dispose()
        log.info("app_stopped")


def create_app() -> FastAPI:
    """组装并返回 FastAPI 应用实例（装配顺序对所有形态一致）。"""
    config = get_app_config()
    setup_logging(level=config.log_level, fmt=config.log_format)

    application = FastAPI(
        title="Remember API",
        description="Remember —— 课表、笔记与课堂录音服务",
        version=config.version,
        lifespan=lifespan,
    )
    if config.deployment_mode == "local":
        pairing = PairingService(config.resolved_pairing_state_path, config.port)
        application.state.pairing_service = pairing
        if config.pairing_discovery_enabled:
            application.state.pairing_discovery = PairingDiscovery(
                pairing, config.pairing_discovery_port
            )
        application.add_middleware(LanPairingMiddleware, pairing=pairing)

    # 中间件顺序：先加鉴权（内层），后加请求 ID（外层），
    # 使 request_id 覆盖包括鉴权失败在内的所有请求。
    if config.auth_enabled:
        application.add_middleware(AuthMiddleware, auth_token=config.auth_token)
    application.add_middleware(RequestIdMiddleware)
    application.add_middleware(UploadProgressMiddleware)

    register_exception_handlers(application)
    application.include_router(api_router, prefix="/api")

    static_dir = Path(__file__).resolve().parent / "static"
    if static_dir.exists():
        from fastapi.staticfiles import StaticFiles
        application.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

    static_index = static_dir / "index.html"

    @application.get("/", include_in_schema=False)
    async def serve_index():
        from fastapi.responses import FileResponse, HTMLResponse
        if static_index.exists():
            return FileResponse(static_index)
        return HTMLResponse("<h1>Remember</h1><p><a href='/docs'>Swagger API Docs</a></p>")

    return application


app = create_app()


if __name__ == "__main__":
    _config = get_app_config()
    uvicorn.run(
        app,
        host=_config.host,
        port=_config.port,
        log_level=_config.log_level.lower(),
    )
