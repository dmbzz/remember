"""视觉 / 多模态 Provider 实现集合。"""

from app.providers.vision.cloud_vision import CloudVisionProvider
from app.providers.vision.local_vision import LocalVisionProvider

__all__ = ["CloudVisionProvider", "LocalVisionProvider"]
