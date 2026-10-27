"""本地文件系统存储 Provider —— 落地数据目录（目录由配置提供）。"""

from __future__ import annotations

import asyncio
import hashlib
import mimetypes
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from app.errors import ErrorCode, ProviderError
from app.providers.base import BlobMeta, ProviderCapabilities, StorageProvider

__all__ = ["LocalFileStorageProvider"]


class LocalFileStorageProvider(StorageProvider):
    """基于本地文件系统的存储实现。"""

    default_name = "local_fs"

    @property
    def root(self) -> Path:
        configured = getattr(self._config, "resolved_storage_root", None)
        base = Path(configured) if configured is not None else Path(tempfile.gettempdir())
        return base

    def _key_path(self, key: str) -> Path:
        """将 key 映射到 root 下的安全路径（禁止越出 root）。"""
        clean = key.lstrip("/\\").replace("\\", "/")
        target = (self.root / clean).resolve()
        root_resolved = self.root.resolve()
        if root_resolved != target and root_resolved not in target.parents:
            raise ProviderError(
                f"非法 key（越出存储根目录）：{key}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        return target

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name=self.name,
            kind="storage",
            runs_offline=True,
            incurs_cost=False,
            supports_streaming=False,
            extra={"root": str(self.root)},
        )

    @staticmethod
    def _put_sync(local_path: str, target: Path) -> str:
        source = Path(local_path)
        if not source.exists():
            raise ProviderError(
                f"待存储文件不存在：{local_path}",
                provider="local_fs",
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.resolve() != target.resolve():
            shutil.copy2(source, target)
        return target.resolve().as_uri()

    async def put(self, local_path: str, key: str) -> str:
        """拷贝本地文件到 ``root/key``，返回 file URI。"""
        return await asyncio.to_thread(self._put_sync, local_path, self._key_path(key))

    async def get(self, key: str, dest_path: str | None = None) -> str:
        """将 ``key`` 拷贝到 ``dest_path``（或临时目录），返回本地路径。"""
        source = self._key_path(key)
        if not source.exists():
            raise ProviderError(
                f"存储对象不存在：{key}",
                provider=self.name,
                code=ErrorCode.NOT_FOUND,
                retryable=False,
            )
        if dest_path:
            destination = Path(dest_path)
        else:
            suffix = source.suffix
            handle = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
            handle.close()
            destination = Path(handle.name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        await asyncio.to_thread(shutil.copy2, source, destination)
        return str(destination)

    async def delete(self, key: str) -> None:
        """删除 ``key``（不存在时静默）。"""
        target = self._key_path(key)
        if target.exists():
            await asyncio.to_thread(target.unlink)

    async def exists(self, key: str) -> bool:
        """判断 ``key`` 是否存在。"""
        return self._key_path(key).exists()

    async def list(self, prefix: str = "") -> list[str]:
        """列出 ``prefix`` 下的所有相对 key。"""
        base = self._key_path(prefix) if prefix else self.root
        if not base.exists():
            return []
        keys: list[str] = []
        for path in sorted(base.rglob("*")):
            if path.is_file():
                keys.append(path.relative_to(self.root).as_posix())
        return keys

    # ------------------------------------------------------------------
    # 元数据（v3.0 加宽）：供同步 hash + mtime 增量 diff
    # ------------------------------------------------------------------
    @staticmethod
    def _file_sha256(path: Path) -> str:
        """计算文件内容的 sha256（十六进制）。"""
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def _blob_meta(self, path: Path) -> BlobMeta:
        """由本地文件构造 ``BlobMeta``（etag = 内容 sha256）。"""
        stat = path.stat()
        content_type, _ = mimetypes.guess_type(path.name)
        return BlobMeta(
            key=path.relative_to(self.root).as_posix(),
            size=stat.st_size,
            etag=self._file_sha256(path),
            last_modified=datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc),
            content_type=content_type,
        )

    def _stat_sync(self, key: str) -> BlobMeta:
        target = self._key_path(key)
        if not target.is_file():
            raise ProviderError(
                f"存储对象不存在：{key}",
                provider=self.name,
                code=ErrorCode.NOT_FOUND,
                retryable=False,
            )
        return self._blob_meta(target)

    def _list_with_meta_sync(self, prefix: str) -> list[BlobMeta]:
        base = self._key_path(prefix) if prefix else self.root
        if not base.exists():
            return []
        return [
            self._blob_meta(path) for path in sorted(base.rglob("*")) if path.is_file()
        ]

    async def stat(self, key: str) -> BlobMeta:
        """返回单个 blob 的元数据（size / etag(sha256) / mtime）。"""
        return await asyncio.to_thread(self._stat_sync, key)

    async def list_with_meta(self, prefix: str = "") -> list[BlobMeta]:
        """列出 ``prefix`` 下所有 blob 的元数据（不下载正文）。"""
        return await asyncio.to_thread(self._list_with_meta_sync, prefix)

    async def presign_put(self, key: str) -> str:
        """本地模式无预签名概念，直接返回目标文件路径（URI）。"""
        return self._key_path(key).resolve().as_uri()

