"""本机路径设置和只读笔记清单。"""
from __future__ import annotations

import hashlib
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

import app.config as config_module
from app.config import AppConfig
from app.deps import get_config
from app.main import create_app
from app.services.vault_notes_service import VaultNotesService


@pytest.mark.asyncio
async def test_local_paths_only_from_computer_and_persisted(tmp_path: Path, monkeypatch):
    vault = tmp_path / "Obsidian"
    vault.mkdir()
    recordings = tmp_path / "my_recordings"
    recordings.mkdir()
    user_config = tmp_path / "config.user.yaml"
    monkeypatch.setattr(config_module, "USER_CONFIG_FILE", user_config)
    config = AppConfig(_env_file=None, deployment_mode="local",
                       obsidian_root=str(vault), storage_root=str(tmp_path / "storage"))
    app = create_app()
    app.dependency_overrides[get_config] = lambda: config
    async with AsyncClient(transport=ASGITransport(app=app, client=("127.0.0.1", 123)),
                           base_url="http://test") as client:
        response = await client.put("/api/settings/local-paths",
                                    json={"recordings_root": str(recordings)})
        assert response.status_code == 200
        assert Path(response.json()["data"]["recordings_root"]) == recordings
        assert Path((await client.get("/api/settings/local-paths")).json()["data"]["obsidian_root"]) == vault
    assert "recordings_root" in user_config.read_text(encoding="utf-8")
    assert not (vault / "课堂笔记").exists()  # 设置路径不会移动或创建用户笔记
    async with AsyncClient(transport=ASGITransport(app=app, client=("192.168.1.8", 123)),
                           base_url="http://test") as client:
        assert (await client.put("/api/settings/local-paths",
                                 json={"recordings_root": str(recordings)})).status_code == 401


def test_manifest_reads_markdown_without_modifying(tmp_path: Path):
    notes = tmp_path / "课堂笔记" / "普通物理"
    notes.mkdir(parents=True)
    source = notes / "波动_2026-10-10.md"
    content = "# 波动\n$u=\\sqrt{2}U$\n".encode("utf-8")
    source.write_bytes(content)
    excluded = tmp_path / "课堂笔记" / "00-任务规划"
    excluded.mkdir()
    (excluded / "暂存.md").write_text("skip", encoding="utf-8")
    config = AppConfig(_env_file=None, obsidian_root=str(tmp_path))
    items = VaultNotesService(config).manifest()
    assert items == [{"path": "普通物理/波动_2026-10-10.md",
                      "sha256": hashlib.sha256(content).hexdigest()}]
    assert source.read_bytes() == content
