"""存储 Provider 实现集合。"""

from app.providers.storage.local_fs import LocalFileStorageProvider
from app.providers.storage.object_store import ObjectStorageProvider

__all__ = ["LocalFileStorageProvider", "ObjectStorageProvider"]

