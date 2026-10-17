# GeoStrix predictive-modelling add-on (TASKS.csv #638) — local HTTP server around the geoML models.
# Copyright (C) 2026 Matt Mendes. GNU GPL v3 (see ../LICENSE).
#
# Same rules as GeoStrix's own Python engine (python-sidecar/app/main.py): 127.0.0.1 only, a per-launch token in
# X-GeoStrix-Token (from GEOSTRIX_ADDON_TOKEN; none needed when unset, for a developer running it by hand), a Host
# check against DNS rebinding, a request-size cap, one job at a time. Each job runs in its own process (spawn): the
# parent never imports TensorFlow, so /health answers at once, and Cancel terminates the child, which returns every
# byte of its memory to the system immediately.
import hmac
import multiprocessing as mp
import os
import queue
import threading
import time
import traceback
import uuid
from importlib import metadata

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware

ADDON_VERSION = "0.1.0"
_TOKEN = os.environ.get("GEOSTRIX_ADDON_TOKEN") or None
MAX_BODY_BYTES = 60 * 1024 * 1024
_CORS = {"Access-Control-Allow-Origin": "*"}

app = FastAPI(title="GeoStrix predictive modelling (geoML)")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET", "POST"], allow_headers=["*"])
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"])


@app.middleware("http")
async def _guard(request: Request, call_next):
    if request.method == "OPTIONS":
        return await call_next(request)
    cl = request.headers.get("content-length")
    try:
        n = int(cl) if cl is not None else None
    except ValueError:
        return JSONResponse(status_code=400, content={"detail": "Content-Length is not a number."}, headers=_CORS)
    if request.method == "POST" and (n is None or n > MAX_BODY_BYTES):
        return JSONResponse(status_code=413, content={"detail": f"Request body missing a length or larger than {MAX_BODY_BYTES // 2 ** 20} MB."}, headers=_CORS)
    if _TOKEN and request.url.path != "/health":
        if not hmac.compare_digest(request.headers.get("x-geostrix-token", ""), _TOKEN):
            return JSONResponse(status_code=401, content={"detail": "Missing or wrong add-on token."}, headers=_CORS)
    return await call_next(request)


def _version(dist):
    try:
        return metadata.version(dist)
    except Exception:
        return None


# ---------- jobs: one child process each ----------
def _child(kind, params, q):
    def watch_parent():  # the add-on server died (app quit / killed): don't live on holding gigabytes
        parent = mp.parent_process()
        while True:
            time.sleep(2)
            if parent is None or not parent.is_alive():
                os._exit(0)
    threading.Thread(target=watch_parent, daemon=True).start()
    try:
        q.put(("progress", 0.01, "Starting TensorFlow and geoML"))
        from geostrix_geoml import models
        result = models.JOBS[kind](params, lambda f, text: q.put(("progress", float(f), str(text))))
        q.put(("done", result))
    except Exception as e:  # noqa: BLE001 — every failure goes back to GeoStrix with its message
        q.put(("error", f"{type(e).__name__}: {e}", traceback.format_exc()[-4000:]))


class Jobs:
    def __init__(self):
        self.jobs, self.lock = {}, threading.Lock()

    def running(self):
        return next((j for j in self.jobs.values() if j["state"] == "running"), None)

    def start(self, kind, params):
        ctx = mp.get_context("spawn")
        q = ctx.Queue()
        proc = ctx.Process(target=_child, args=(kind, params, q), daemon=True)
        jid = uuid.uuid4().hex[:12]
        job = {"id": jid, "kind": kind, "state": "running", "progress": 0.0, "message": "Queued", "started": time.time(), "proc": proc, "q": q, "result": None, "error": None}
        with self.lock:
            self.jobs[jid] = job
        proc.start()
        threading.Thread(target=self._pump, args=(job,), daemon=True).start()
        return job

    def _pump(self, job):
        while job["state"] == "running":
            try:
                msg = job["q"].get(timeout=1)
            except queue.Empty:
                if not job["proc"].is_alive():
                    job.update(state="error", error="The modelling process stopped unexpectedly (out of memory?).")
                continue
            if msg[0] == "progress":
                job["progress"], job["message"] = msg[1], msg[2]
            elif msg[0] == "done":
                job.update(state="done", result=msg[1], progress=1.0, message="Done")
            elif msg[0] == "error":
                job.update(state="error", error=msg[1], trace=msg[2])
        job["proc"].join(timeout=5)

    def cancel(self, jid):
        job = self.jobs.get(jid)
        if not job or job["state"] != "running":
            return False
        job["proc"].terminate()
        job.update(state="cancelled", message="Cancelled")
        return True


manager = Jobs()


def _public(job):
    return {k: job.get(k) for k in ("id", "kind", "state", "progress", "message", "error")} | {"elapsed": round(time.time() - job["started"], 1)}


@app.get("/health")
def health():
    return {"ok": True, "addon": "geoml", "version": ADDON_VERSION, "geoml": _version("geoml"), "tensorflow": _version("tensorflow"),
            "busy": manager.running() is not None}


@app.post("/v1/jobs")
async def submit(request: Request):
    body = await request.json()
    kind = body.get("kind")
    if kind not in ("domain", "grade"):
        return JSONResponse(status_code=400, content={"detail": "kind must be 'domain' or 'grade'."}, headers=_CORS)
    busy = manager.running()
    if busy:
        return JSONResponse(status_code=409, content={"detail": "A predictive model is already running — wait for it or cancel it first.", "job": _public(busy)}, headers=_CORS)
    return _public(manager.start(kind, body.get("params") or {}))


@app.get("/v1/jobs/{jid}")
def status(jid: str):
    job = manager.jobs.get(jid)
    return _public(job) if job else JSONResponse(status_code=404, content={"detail": "No such job."}, headers=_CORS)


@app.get("/v1/jobs/{jid}/result")
def result(jid: str):
    job = manager.jobs.get(jid)
    if not job or job["state"] != "done":
        return JSONResponse(status_code=404, content={"detail": "No finished result for this job."}, headers=_CORS)
    return job["result"]


@app.post("/v1/jobs/{jid}/cancel")
def cancel(jid: str):
    return {"cancelled": manager.cancel(jid)}
