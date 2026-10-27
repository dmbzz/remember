"""Small atomic progress receipts. Percentages describe completed inference shards only."""
import json
import logging
from pathlib import Path
from app.services.atomic_files import atomic_json

def update_progress(work, phase, completed=None, total=None, generation=None):
    path = Path(work) / "progress.json"
    previous = {}
    if path.exists():
        try:
            previous = json.loads(path.read_text("utf-8"))
        except (OSError, ValueError):
            pass
    try:
        atomic_json(path, {"generation": generation if generation is not None else previous.get("generation"),
                           "phase": phase, "completed_chunks": completed, "total_chunks": total})
    except OSError:
        logging.getLogger(__name__).warning('ASR progress update unavailable; inference continues')

def read_progress(job, work_root):
    if job.status != "running":
        return {"phase": job.status, "completed_chunks": None, "total_chunks": None}
    try:
        value = json.loads((Path(work_root) / job.id / "progress.json").read_text("utf-8"))
        if value.get("generation") == job.run_generation:
            return value
    except (OSError, ValueError):
        pass
    return {"phase": "preparing", "completed_chunks": None, "total_chunks": None}
