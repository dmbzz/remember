"""Curated local ASR choices. VRAM values are recommendations, not measured guarantees."""
import csv
import io
import os
from pathlib import Path
import shutil
import subprocess

CATALOG = [
    dict(id='qwen-0.6b', name='Qwen3-ASR 0.6B', engine='qwen', hf='Qwen/Qwen3-ASR-0.6B', ms='Qwen/Qwen3-ASR-0.6B',
         vram_gb=4, download_gb=3.8, description='中文优先 · 低显存推荐。时间戳对齐在 CPU 上执行，减少显存占用。',
         source='https://huggingface.co/Qwen/Qwen3-ASR-0.6B', license='Apache-2.0'),
    dict(id='qwen-1.7b', name='Qwen3-ASR 1.7B', engine='qwen', hf='Qwen/Qwen3-ASR-1.7B', ms='Qwen/Qwen3-ASR-1.7B',
         vram_gb=8, download_gb=6.6, description='中文准确度优先 · 建议 8GB 显存；小显存可选 CPU，速度会降低。',
         source='https://huggingface.co/Qwen/Qwen3-ASR-1.7B', license='Apache-2.0'),
    dict(id='whisper-turbo', name='Whisper large-v3-turbo · INT8', engine='whisper', hf='dropbox-dash/faster-whisper-large-v3-turbo', ms=None,
         vram_gb=4, download_gb=1.7, description='中文/外语混合备选 · CTranslate2 INT8，单批次运行。',
         source='https://huggingface.co/dropbox-dash/faster-whisper-large-v3-turbo', license='MIT'),
    dict(id='whisper-small', name='Whisper Small · INT8', engine='whisper', hf='Systran/faster-whisper-small', ms=None,
         vram_gb=2, download_gb=.5, description='极低显存 / CPU 备选 · 更省资源，中文复杂课堂优先考虑 Qwen。',
         source='https://huggingface.co/Systran/faster-whisper-small', license='MIT'),
]

def model_by_id(ident):
    for model in CATALOG:
        if model['id'] == ident:
            return dict(model)
    raise ValueError('请选择列表中的模型')

def detect_hardware():
    candidates = [Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/nvidia-smi.exe',
                  Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'NVIDIA Corporation/NVSMI/nvidia-smi.exe']
    executable = next((str(p) for p in candidates if p.is_file()), None) or shutil.which('nvidia-smi')
    gpus, error = [], None
    if executable:
        try:
            result = subprocess.run([executable, '--query-gpu=index,name,memory.total,memory.free,driver_version',
                         '--format=csv,noheader,nounits'], capture_output=True, timeout=8,
                         creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            if result.returncode:
                raise ValueError('NVIDIA 驱动查询未成功')
            for row in csv.reader(io.StringIO(result.stdout.decode('utf-8', errors='replace'))):
                if len(row) != 5:
                    continue
                index, name, total, free, driver = [x.strip() for x in row]
                gpus.append(dict(index=int(index), name=name, memory_mb=int(float(total)), free_mb=int(float(free)), driver=driver))
        except (OSError, ValueError, subprocess.TimeoutExpired):
            error = '未确认 NVIDIA 驱动与显存，可用 CPU 部署；请更新驱动后重新检测。'
    else:
        error = '未找到可用的 NVIDIA 查询工具；这不代表机器一定没有独显。可先选 CPU。'
    gpus.sort(key=lambda g: g['memory_mb'], reverse=True)
    gpu = gpus[0] if gpus else None
    driver_major = int(gpu['driver'].split('.')[0]) if gpu and gpu['driver'].split('.')[0].isdigit() else 0
    cuda = 'cu128' if driver_major >= 570 else 'cu126' if driver_major >= 561 else None
    recommended = 'qwen-1.7b' if gpu and cuda and gpu['memory_mb'] >= 7500 else (
        'qwen-0.6b' if gpu and cuda and gpu['memory_mb'] >= 3500 else 'whisper-small')
    if gpu and not cuda:
        error = '已发现 NVIDIA 显卡，但驱动版本较旧；默认使用 CPU，更新驱动后可重新检测。'
    return dict(gpus=gpus, selected_gpu=gpu['index'] if gpu else 0, cuda_runtime=cuda,
                recommended_id=recommended, message=error or '已检测 NVIDIA 显卡；最终 CUDA 可用性由环境与音频测试确认。',
                vram_note='显存建议为保守选型值，实际占用取决于驱动、音频和其他程序；不是实测保证。')
