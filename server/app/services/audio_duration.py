"""Read durations of the recorder's WAV/MP4 containers without a model runtime."""
from __future__ import annotations

from pathlib import Path
import struct
import wave


def audio_duration(path: Path) -> float | None:
    try:
        with path.open('rb') as stream:
            signature = stream.read(12)
        if signature[:4] == b'RIFF' and signature[8:12] == b'WAVE':
            with wave.open(str(path), 'rb') as audio:
                duration = audio.getnframes() / audio.getframerate()
                return duration if duration > 0 else None
        if signature[4:8] != b'ftyp':
            return None
        with path.open('rb') as stream:
            limit = path.stat().st_size
            # Only traverse root/moov boxes, skipping media data without reading it.
            regions = [(0, limit)]
            budget = 10000
            while regions and budget > 0:
                offset, end = regions.pop()
                while offset + 8 <= end and budget > 0:
                    budget -= 1
                    stream.seek(offset)
                    size, kind = struct.unpack('>I4s', stream.read(8))
                    header = 8
                    if size == 1:
                        size = struct.unpack('>Q', stream.read(8))[0]
                        header = 16
                    elif size == 0:
                        size = end - offset
                    if size < header or offset + size > end:
                        return None
                    if kind == b'moov' and len(regions) < 4:
                        regions.append((offset + header, offset + size))
                    elif kind == b'mvhd':
                        data = stream.read(min(32, size - header))
                        if len(data) >= 20 and data[0] == 0:
                            scale, ticks = struct.unpack('>II', data[12:20])
                            unknown = 0xffffffff
                        elif len(data) >= 32 and data[0] == 1:
                            scale, ticks = struct.unpack('>IQ', data[20:32])
                            unknown = 0xffffffffffffffff
                        else:
                            return None
                        return ticks / scale if scale > 0 and 0 < ticks < unknown else None
                    offset += size
    except (OSError, EOFError, ValueError, struct.error, wave.Error, ZeroDivisionError):
        return None
    return None
