from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_root_returns_metadata():
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert body["service"] == "webapp"
    assert body["message"] == "Hello world"
    assert {"version", "environment", "hostname"} <= body.keys()


def test_probes():
    assert client.get("/healthz").json() == {"status": "ok"}
    assert client.get("/readyz").json() == {"status": "ready"}


def test_metrics_exposed():
    client.get("/healthz")
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "http_requests_total" in r.text
