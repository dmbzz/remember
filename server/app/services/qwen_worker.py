"""Standalone worker: run ONLY with configured Qwen Python. No application imports."""
import json
import sys
from pathlib import Path


def sentences(items, offset):
    out, buf = [], []
    def flush():
        if buf:
            out.append({"s": buf[0]["s"], "e": buf[-1]["e"], "t": "".join(x["t"] for x in buf)})
            buf.clear()
    for it in items:
        if not it.text.strip():
            continue
        x = {"s": float(it.start_time) + offset, "e": float(it.end_time) + offset, "t": it.text.strip()}
        if buf and x["s"] - buf[-1]["e"] > .45:
            flush()
        buf.append(x)
        if len(buf) >= 40:
            flush()
    flush()
    return out


def main(request_path, device):
    import torch
    from qwen_asr import Qwen3ASRModel
    request = json.loads(Path(request_path).read_text("utf-8"))
    def progress(phase, done=None, total=None):
        if not request.get("progress_path"):
            return
        path = Path(request["progress_path"])
        temp = path.with_suffix(".worker.tmp")
        try:
            temp.write_text(json.dumps({"generation": request.get("generation"), "phase": phase,
                                       "completed_chunks": done, "total_chunks": total}), "utf-8")
            temp.replace(path)
        except OSError:
            print('Progress update unavailable; inference continues', file=sys.stderr, flush=True)
    phase = request.get("progress_phase", "transcribing")
    progress("tail" if phase == "tail" else "loading")
    dtype = torch.bfloat16 if device == "cuda" else torch.float32
    dev = "cuda:0" if device == "cuda" else "cpu"
    model = Qwen3ASRModel.from_pretrained(
        request["model_path"], forced_aligner=request["aligner_path"],
        forced_aligner_kwargs=dict(dtype=dtype, device_map=dev),
        dtype=dtype, device_map=dev, max_inference_batch_size=4 if device == "cuda" else 1,
        max_new_tokens=2048,
    )
    for index, chunk in enumerate(request["chunks"]):
        progress(phase, index if phase != "tail" else None,
                 len(request["chunks"]) if phase != "tail" else None)
        output = Path(chunk["output"])
        if output.exists():
            continue
        result = model.transcribe(audio=chunk["audio"], context="", language="Chinese", return_time_stamps=True)[0]
        stamps = getattr(result.time_stamps, "items", None) if result.time_stamps else None
        segs = sentences(stamps, chunk["offset"]) if stamps else []
        # Text without alignment is retained, but cannot authorize source deletion.
        if not segs and result.text.strip():
            segs = [{"s": chunk["offset"], "e": chunk["offset"], "t": result.text.strip()}]
        payload = {"segments": segs, "aligned": bool(stamps), "device": device}
        temp = output.with_suffix(".tmp")
        temp.write_text(json.dumps(payload, ensure_ascii=False), "utf-8")
        temp.replace(output)
        progress(phase, index + 1 if phase != "tail" else None,
                 len(request["chunks"]) if phase != "tail" else None)
        print(output.name, flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
