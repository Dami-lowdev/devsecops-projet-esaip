"""Tests simples du frontend APP1 (sans backend réel : on mocke `requests`)."""
import app as frontend
import pytest


class FakeResp:
    def __init__(self, payload):
        self._payload = payload

    def json(self):
        return self._payload


@pytest.fixture
def client(monkeypatch):
    # On neutralise les appels réseau vers APP2.
    monkeypatch.setattr(frontend.requests, "get",
                        lambda *a, **k: FakeResp([{"id": 1, "title": "demo", "done": False}]))
    monkeypatch.setattr(frontend.requests, "post", lambda *a, **k: FakeResp({}))
    monkeypatch.setattr(frontend.requests, "delete", lambda *a, **k: FakeResp({}))
    frontend.app.config["TESTING"] = True
    return frontend.app.test_client()


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_index_liste_les_todos(client):
    r = client.get("/")
    assert r.status_code == 200
    assert b"demo" in r.data            # le todo renvoyé par le backend mocké s'affiche


def test_add_redirige(client):
    r = client.post("/add", data={"title": "nouvelle tache"})
    assert r.status_code == 302         # redirection vers l'index après ajout


def test_delete_redirige(client):
    r = client.post("/delete/1")
    assert r.status_code == 302
