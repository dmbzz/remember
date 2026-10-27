import asyncio
import threading
import httpx
import pytest

from app.services.asr_engine import service_infer
from app.services.asr_settings import AsrSettings


@pytest.mark.parametrize("with_timestamps", [True, False])
async def test_qwen_service_response_and_optional_key(tmp_path, monkeypatch, with_timestamps):
    source = tmp_path / 'test.wav'
    source.write_bytes(b'isolated sample')
    original = httpx.AsyncClient
    def handle(request):
        assert request.url.path == '/v1/audio/transcriptions'
        assert 'authorization' not in request.headers
        payload = {'text': '测试文本'}
        if with_timestamps:
            payload.update(duration=3, segments=[{'start': 0, 'end': 3, 'text': '测试文本'}])
        return httpx.Response(200, json=payload)
    monkeypatch.setattr(httpx, 'AsyncClient', lambda **kwargs: original(transport=httpx.MockTransport(handle)))
    result = await service_infer(source, AsrSettings(mode='qwen_service', base_url='http://qwen/v1'), threading.Event())
    assert result['segments'][0]['t'] == '测试文本'
    assert result['aligned'] == with_timestamps


async def test_unsupported_verbose_has_only_one_json_fallback(tmp_path, monkeypatch):
    source = tmp_path / 'test.wav'
    source.write_bytes(b'sample')
    original = httpx.AsyncClient
    calls = []
    async def handle(request):
        body = await request.aread()
        calls.append(body)
        if len(calls) == 1:
            assert b'verbose_json' in body
            return httpx.Response(400, text='Unsupported response_format')
        assert b'verbose_json' not in body
        return httpx.Response(200, json={'text': '有效结果'})
    monkeypatch.setattr(httpx, 'AsyncClient', lambda **kwargs: original(transport=httpx.MockTransport(handle)))
    value = await service_infer(source, AsrSettings(mode='qwen_service', base_url='http://qwen/v1'), threading.Event())
    assert len(calls) == 2 and not value['aligned']


async def test_shutdown_cancels_http_and_preserves_source(tmp_path, monkeypatch):
    source = tmp_path / 'test.wav'
    source.write_bytes(b'sample')
    original = httpx.AsyncClient
    entered = asyncio.Event()
    closed = asyncio.Event()
    async def handle(request):
        entered.set()
        try:
            await asyncio.sleep(100)
        finally:
            closed.set()
    monkeypatch.setattr(httpx, 'AsyncClient', lambda **kwargs: original(transport=httpx.MockTransport(handle)))
    stop = threading.Event()
    task = asyncio.create_task(service_infer(source, AsrSettings(mode='qwen_service', base_url='http://qwen/v1'), stop))
    await entered.wait()
    stop.set()
    with pytest.raises(RuntimeError):
        await asyncio.wait_for(task, 2)
    assert closed.is_set() and source.read_bytes() == b'sample'
