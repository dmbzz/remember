"""转写 Provider 实现集合。"""

from app.providers.transcription.cloud_api import CloudASRProvider
from app.providers.transcription.local_gpu import LocalGPUWhisperProvider
from app.providers.transcription.on_device import OnDeviceProvider

__all__ = ["LocalGPUWhisperProvider", "CloudASRProvider", "OnDeviceProvider"]
