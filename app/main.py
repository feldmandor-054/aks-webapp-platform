"""Minimal web service used to exercise the deployment platform.

Endpoints:
  GET /         -> service metadata (version, hostname)
  GET /healthz  -> liveness probe: process is up
  GET /readyz   -> readiness probe: dependencies are reachable (none here, so 200)
  GET /metrics  -> Prometheus exposition format
"""

from __future__ import annotations

import os
import socket
import time

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

APP_VERSION = os.getenv("APP_VERSION", "dev")
APP_ENV = os.getenv("APP_ENV", "local")

app = FastAPI(title="webapp", version=APP_VERSION, docs_url=None, redoc_url=None)

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "path", "status"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP request latency", ["method", "path"])


@app.middleware("http")
async def record_metrics(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    path = request.url.path
    if path != "/metrics":
        LATENCY.labels(request.method, path).observe(time.perf_counter() - start)
        REQUESTS.labels(request.method, path, str(response.status_code)).inc()
    return response


@app.get("/")
def root() -> dict[str, str]:
    return {
        "service": "webapp",
        "version": APP_VERSION,
        "environment": APP_ENV,
        "hostname": socket.gethostname(),
        "message": "Hello world",
    }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    # Extend with dependency checks (DB ping, cache ping) when the app has any.
    return {"status": "ready"}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
