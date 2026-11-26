"""Obsidian 笔记图片读取与附件同步专项测试。"""

from __future__ import annotations

import base64
import hashlib
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import AppConfig
from app.db.base import Base
from app.deps import get_config, get_db
from app.main import create_app
from app.services.note_check_service import NoteCheckRequest, NoteCheckService
from app.services.note_choice_service import ChoiceScope, NoteChoiceRequest, NoteChoiceService
from app.services.note_file_sync_service import NoteFileSyncService
from app.services.vault_notes_service import VaultNotesService

# 1x1 合法 PNG 字节
_TINY_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


@pytest.mark.asyncio
async def test_note_asset_and_image_sync_flow(tmp_path: Path):
    vault = tmp_path / "vault"
    course_dir = vault / "课堂笔记" / "工程力学"
    fig_dir = course_dir / "_图"
    fig_dir.mkdir(parents=True)
    hidden_dir = vault / "课堂笔记" / "00-教材导览"
    hidden_dir.mkdir(parents=True)

    note_file = course_dir / "受力图_2026-09-08.md"
    note_file.write_text("# 受力图\n\n![[工程力学_习题1-4.png|420]]\n", encoding="utf-8")
    img_file = fig_dir / "工程力学_习题1-4.png"
    img_file.write_bytes(_TINY_PNG)
    (hidden_dir / "私密图.png").write_bytes(_TINY_PNG)
    (course_dir / "忽略文本.txt").write_text("not synced", encoding="utf-8")

    db_url = f"sqlite+aiosqlite:///{tmp_path / 'img.db'}"
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
        # 1. /api/notes 列表只返回 Markdown 笔记，不把图片混入笔记列表
        notes_resp = await client.get("/api/notes")
        assert notes_resp.status_code == 200
        assert notes_resp.json()["data"]["total"] == 1
        note_id = notes_resp.json()["data"]["items"][0]["note_id"]

        # 2. /api/notes/asset 支持短链跨 _图/ 读取，以及带 |宽度 参数或相对路径读取
        for ref in ("工程力学_习题1-4.png", "工程力学_习题1-4.png|420", "_图/工程力学_习题1-4.png"):
            res = await client.get(
                "/api/notes/asset",
                params={"ref": ref, "note_id": note_id, "course": "工程力学"},
            )
            assert res.status_code == 200
            assert res.headers["content-type"] == "image/png"
            assert res.content == _TINY_PNG

        # 3. 安全拦截：目录穿越、隐藏目录、非图片文件均拒绝
        for bad_ref in ("../outside.png", "00-教材导览/私密图.png", "受力图_2026-09-08.md", "http://example.com/a.png"):
            bad_res = await client.get("/api/notes/asset", params={"ref": bad_ref})
            assert bad_res.status_code in (400, 422)

        # 4. 同步清单包含图片附件，且能下载图片字节与选择电脑版图片同步
        manifest_resp = await client.get("/api/notes/file-sync/manifest")
        assert manifest_resp.status_code == 200
        manifest = manifest_resp.json()["data"]
        paths = {item["path"]: item["sha256"] for item in manifest["items"]}
        assert "工程力学/受力图_2026-09-08.md" in paths
        assert "工程力学/_图/工程力学_习题1-4.png" in paths
        assert "工程力学/忽略文本.txt" not in paths

        dl = await client.get(
            "/api/notes/file-sync/content",
            params={
                "path": "工程力学/_图/工程力学_习题1-4.png",
                "sha256": paths["工程力学/_图/工程力学_习题1-4.png"],
                "vault_id": manifest["vault_id"],
            },
        )
        assert dl.status_code == 200
        assert base64.b64decode(dl.json()["data"]["content_base64"]) == _TINY_PNG

    # 5. NoteCheckService 与 NoteChoiceService 允许同步图片附件
    check_svc = NoteCheckService(config)
    device_id = "a" * 32
    folder_id = "b" * 64
    report = check_svc.record(
        NoteCheckRequest(
            device_id=device_id,
            folder_label="课堂笔记",
            folder_id=folder_id,
            items=[
                {
                    "path": "工程力学/受力图_2026-09-08.md",
                    "sha256": hashlib.sha256(note_file.read_bytes()).hexdigest(),
                }
            ],
        )
    )
    assert "工程力学/_图/工程力学_习题1-4.png" in report["only_on_computer"]

    choice_svc = NoteChoiceService(config)
    choice = choice_svc.choose(
        NoteChoiceRequest(
            device_id=device_id,
            folder_id=folder_id,
            vault_id=manifest["vault_id"],
            path="工程力学/_图/工程力学_习题1-4.png",
            source="computer",
            phone_hash=None,
            computer_hash=paths["工程力学/_图/工程力学_习题1-4.png"],
        )
    )
    assert choice["status"] == "pending"

    await engine.dispose()
