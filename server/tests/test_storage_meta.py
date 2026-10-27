"""存储 Provider 加宽冒烟测试（v3.0，FR-31）。

验证 ``StorageProvider`` 新增的 ``stat()`` / ``list_with_meta()`` 能暴露 blob 元数据
（``size`` / ``etag``(sha256) / ``last_modified``），以支撑笔记多端同步的 **hash + mtime** 增量 diff。
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from app.errors import ErrorCode, ProviderError
from app.providers.storage.local_fs import LocalFileStorageProvider

_REL_KEY = "课堂笔记/工程力学/静力学_2026-09-16.md"


@pytest.fixture
def storage(tmp_path: Path) -> LocalFileStorageProvider:
    """构造落在临时目录的本地存储 Provider（避免污染真实数据目录）。"""
    root = tmp_path / "_storage"
    root.mkdir(parents=True, exist_ok=True)
    config = SimpleNamespace(resolved_storage_root=root)
    return LocalFileStorageProvider(config)


async def test_stat_and_list_with_meta(storage: LocalFileStorageProvider, tmp_path: Path) -> None:
    """put 后 stat 返回 sha256 etag / size / mtime；list_with_meta 返回同构元数据。"""
    source = tmp_path / "note.md"
    source.write_text("# 静力学\n\n融合式笔记正文。", encoding="utf-8")
    await storage.put(str(source), _REL_KEY)

    meta = await storage.stat(_REL_KEY)
    assert meta.key == _REL_KEY
    assert meta.size > 0
    assert meta.etag is not None and len(meta.etag) == 64  # sha256 hex
    assert meta.last_modified is not None

    metas = await storage.list_with_meta("课堂笔记")
    assert len(metas) == 1
    assert metas[0].etag == meta.etag  # 同一内容 → hash 一致（判新旧依据）


async def test_stat_missing_raises_not_found(storage: LocalFileStorageProvider) -> None:
    """stat 不存在的 key → ProviderError(code=NOT_FOUND)。"""
    with pytest.raises(ProviderError) as excinfo:
        await storage.stat("不存在.md")
    assert excinfo.value.code == ErrorCode.NOT_FOUND
