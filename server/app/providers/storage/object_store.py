"""对象存储 Provider（S3 / OSS / MinIO 兼容）—— 云端模式。

依赖 ``boto3``（可选，惰性 import）；支持预签名直传（分片上传用，FR-05）。
"""

from __future__ import annotations

import asyncio
import tempfile
from datetime import datetime
from pathlib import Path

from app.errors import ErrorCode, ProviderError
from app.providers.base import BlobMeta, ProviderCapabilities, StorageProvider

__all__ = ["ObjectStorageProvider"]


class ObjectStorageProvider(StorageProvider):
    """基于 boto3 的 S3 兼容对象存储实现。"""

    default_name = "object_store"

    @property
    def endpoint(self) -> str | None:
        value = self.settings().get("endpoint")
        return str(value) if value else None

    @property
    def bucket(self) -> str:
        return str(self.settings().get("bucket", "") or "")

    @property
    def access_key(self) -> str:
        return str(self.settings().get("access_key", "") or "")

    @property
    def secret_key(self) -> str:
        return str(self.settings().get("secret_key", "") or "")

    @property
    def region(self) -> str:
        return str(self.settings().get("region", "") or "")

    @property
    def prefix(self) -> str:
        return str(self.settings().get("prefix", "") or "")

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            name=self.name,
            kind="storage",
            runs_offline=False,
            incurs_cost=True,
            supports_streaming=True,
            extra={"bucket": self.bucket, "endpoint": self.endpoint or "aws"},
        )

    def _client(self):  # noqa: ANN202 - 返回 boto3 S3 client
        if not self.bucket:
            raise ProviderError(
                "对象存储未配置 bucket",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        try:
            import boto3
        except Exception as exc:  # noqa: BLE001
            raise ProviderError(
                f"未安装 boto3：{exc}",
                provider=self.name,
                code=ErrorCode.PROVIDER_UNAVAILABLE,
                retryable=False,
            ) from exc
        return boto3.client(
            "s3",
            endpoint_url=self.endpoint,
            aws_access_key_id=self.access_key or None,
            aws_secret_access_key=self.secret_key or None,
            region_name=self.region or None,
        )

    def _full_key(self, key: str) -> str:
        clean = key.lstrip("/")
        return f"{self.prefix}{clean}" if self.prefix else clean

    # ------------------------------------------------------------------
    # 同步实现（在线程池执行）
    # ------------------------------------------------------------------
    def _put_sync(self, local_path: str, key: str) -> str:
        source = Path(local_path)
        if not source.exists():
            raise ProviderError(
                f"待上传文件不存在：{local_path}",
                provider=self.name,
                code=ErrorCode.PROVIDER_CONFIG_ERROR,
                retryable=False,
            )
        full_key = self._full_key(key)
        self._client().upload_file(str(source), self.bucket, full_key)
        return f"s3://{self.bucket}/{full_key}"

    def _get_sync(self, key: str, dest_path: str | None) -> str:
        full_key = self._full_key(key)
        if dest_path:
            destination = Path(dest_path)
        else:
            handle = tempfile.NamedTemporaryFile(delete=False, suffix=Path(full_key).suffix)
            handle.close()
            destination = Path(handle.name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        self._client().download_file(self.bucket, full_key, str(destination))
        return str(destination)

    def _delete_sync(self, key: str) -> None:
        self._client().delete_object(Bucket=self.bucket, Key=self._full_key(key))

    def _exists_sync(self, key: str) -> bool:
        try:
            self._client().head_object(Bucket=self.bucket, Key=self._full_key(key))
            return True
        except Exception:  # noqa: BLE001 - 未命中即不存在
            return False

    def _list_sync(self, prefix: str) -> list[str]:
        client = self._client()
        full_prefix = self._full_key(prefix) if prefix else self.prefix
        keys: list[str] = []
        paginator = client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self.bucket, Prefix=full_prefix):
            for item in page.get("Contents", []) or []:
                keys.append(item["Key"])
        return keys

    # ------------------------------------------------------------------
    # 元数据（v3.0 加宽）：供同步 hash + mtime 增量 diff
    # ------------------------------------------------------------------
    @staticmethod
    def _item_to_meta(item: dict) -> BlobMeta:
        """把 S3 ``head_object`` / ``list_objects_v2`` 单条对象转为 ``BlobMeta``。"""
        etag = item.get("ETag")
        if isinstance(etag, str):
            etag = etag.strip('"')
        last_modified = item.get("LastModified")
        if not isinstance(last_modified, datetime):
            last_modified = None
        return BlobMeta(
            key=str(item.get("Key", "")),
            size=int(item.get("Size") or item.get("ContentLength") or 0),
            etag=etag,
            last_modified=last_modified,
            content_type=item.get("ContentType"),
        )

    def _stat_sync(self, key: str) -> BlobMeta:
        full_key = self._full_key(key)
        try:
            head = self._client().head_object(Bucket=self.bucket, Key=full_key)
        except Exception as exc:  # noqa: BLE001 - 未命中即不存在
            raise ProviderError(
                f"对象存储对象不存在：{key}",
                provider=self.name,
                code=ErrorCode.NOT_FOUND,
                retryable=False,
            ) from exc
        head.setdefault("Key", full_key)
        return self._item_to_meta(head)

    def _list_with_meta_sync(self, prefix: str) -> list[BlobMeta]:
        client = self._client()
        full_prefix = self._full_key(prefix) if prefix else self.prefix
        metas: list[BlobMeta] = []
        paginator = client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self.bucket, Prefix=full_prefix):
            for item in page.get("Contents", []) or []:
                metas.append(self._item_to_meta(item))
        return metas

    async def stat(self, key: str) -> BlobMeta:
        """返回单个对象的元数据（size / ETag / LastModified）。"""
        return await asyncio.to_thread(self._stat_sync, key)

    async def list_with_meta(self, prefix: str = "") -> list[BlobMeta]:
        """列出 ``prefix`` 下所有对象及其元数据（不下载正文）。"""
        return await asyncio.to_thread(self._list_with_meta_sync, prefix)

    def _presign_sync(self, key: str) -> str:
        return self._client().generate_presigned_url(
            "put_object",
            Params={"Bucket": self.bucket, "Key": self._full_key(key)},
            ExpiresIn=3600,
        )

    # ------------------------------------------------------------------
    # 异步接口
    # ------------------------------------------------------------------
    async def put(self, local_path: str, key: str) -> str:
        return await asyncio.to_thread(self._put_sync, local_path, key)

    async def get(self, key: str, dest_path: str | None = None) -> str:
        return await asyncio.to_thread(self._get_sync, key, dest_path)

    async def delete(self, key: str) -> None:
        await asyncio.to_thread(self._delete_sync, key)

    async def exists(self, key: str) -> bool:
        return await asyncio.to_thread(self._exists_sync, key)

    async def list(self, prefix: str = "") -> list[str]:
        return await asyncio.to_thread(self._list_sync, prefix)

    async def presign_put(self, key: str) -> str:
        return await asyncio.to_thread(self._presign_sync, key)
