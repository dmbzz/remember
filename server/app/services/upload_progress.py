"""Count actual HTTP request bytes without buffering or changing the upload protocol."""
import re
import time
import uuid

active_uploads = {}

class UploadProgressMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        match = re.fullmatch(r"/api/recordings/([A-Za-z0-9_-]{1,80})/upload-file", scope.get("path", ""))
        if scope["type"] != "http" or scope.get("method") != "POST" or not match:
            return await self.app(scope, receive, send)
        ident, token = match[1], uuid.uuid4().hex
        headers = dict(scope.get("headers", []))
        try:
            total = max(0, int(headers.get(b"content-length", b"0")))
        except ValueError:
            total = 0
        started = False

        def update(**values):
            current = active_uploads.get(ident)
            if current and current["token"] == token:
                current.update(values, updated_at=time.monotonic())

        async def tracked_receive():
            nonlocal started
            message = await receive()
            if message["type"] == "http.request":
                if not started:
                    if len(active_uploads) >= 500:
                        oldest = min(active_uploads, key=lambda key: active_uploads[key]["updated_at"])
                        active_uploads.pop(oldest, None)
                    active_uploads[ident] = dict(token=token, received_bytes=0, total_bytes=total,
                                                 phase="receiving", updated_at=time.monotonic())
                    started = True
                current = active_uploads.get(ident)
                if current and current["token"] == token:
                    update(received_bytes=current["received_bytes"] + len(message.get("body", b"")),
                           phase="receiving" if message.get("more_body") else "saving")
            elif message["type"] == "http.disconnect":
                update(phase="interrupted")
            return message

        async def tracked_send(message):
            if message["type"] == "http.response.start":
                update(phase="received" if message["status"] < 300 else "failed")
            await send(message)

        try:
            await self.app(scope, tracked_receive, tracked_send)
        except BaseException:
            update(phase="interrupted")
            raise

def reception_progress(recording):
    if recording.upload_status == "uploaded":
        return {"phase": "received", "received_bytes": recording.size_bytes, "total_bytes": recording.size_bytes}
    value = active_uploads.get(recording.id)
    if value:
        result = {k: value[k] for k in ("phase", "received_bytes", "total_bytes")}
        if result["phase"] in ("receiving", "saving") and time.monotonic() - value["updated_at"] > 30:
            result["phase"] = "waiting_connection"
        return result
    return {"phase": "waiting", "received_bytes": 0, "total_bytes": recording.size_bytes}
