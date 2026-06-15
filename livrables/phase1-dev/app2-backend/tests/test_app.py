"""Tests simples du backend APP2 (sans PostgreSQL réel : on mocke la connexion)."""
import app as backend
import pytest


class FakeCursor:
    """Curseur PostgreSQL minimal pour les tests."""
    def __init__(self):
        self._rows = [(1, "demo", False, "2026-01-01 00:00:00")]

    def execute(self, sql, *a):
        self.last_sql = sql

    def fetchall(self):
        return self._rows

    def fetchone(self):
        return (1,)

    def close(self):
        pass


class FakeConn:
    def cursor(self):
        return FakeCursor()

    def commit(self):
        pass

    def close(self):
        pass


@pytest.fixture
def client(monkeypatch):
    # On remplace l'accès DB par une fausse connexion.
    monkeypatch.setattr(backend, "db", lambda: FakeConn())
    backend.app.config["TESTING"] = True
    return backend.app.test_client()


def test_health_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_list_todos(client):
    r = client.get("/api/todos")
    assert r.status_code == 200
    data = r.get_json()
    assert isinstance(data, list) and data[0]["title"] == "demo"


def test_create_todo(client):
    r = client.post("/api/todos", json={"title": "acheter du lait"})
    assert r.status_code == 201
    assert r.get_json()["title"] == "acheter du lait"


def test_search(client):
    r = client.get("/api/search?q=demo")
    assert r.status_code == 200
    assert isinstance(r.get_json(), list)


def test_debug_expose_environ(client):
    # Endpoint volontairement vulnérable : on vérifie qu'il répond bien
    # (la faille = il expose os.environ ; corrigée en Phase 3).
    r = client.get("/api/debug")
    assert r.status_code == 200
    assert isinstance(r.get_json(), dict)
