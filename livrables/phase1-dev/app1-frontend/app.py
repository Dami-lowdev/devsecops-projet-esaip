"""
APP1 — Frontend de la Todo App (Flask).

Seul service exposé à l'utilisateur final. Il sert l'interface web et relaie
les actions vers le backend APP2 (server-side). L'utilisateur ne parle JAMAIS
directement à APP2 ni à la DB.

Flux :  Navigateur  --HTTP-->  APP1  --REST-->  APP2  --SQL-->  DB
"""
import os
import logging
import requests
from flask import Flask, render_template, request, redirect, url_for

# --- Configuration par variables d'environnement -------------------------
BACKEND_URL = os.environ.get("BACKEND_URL", "http://todo-backend:5000")
APP_PORT = int(os.environ.get("APP_PORT", "8080"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

logging.basicConfig(level=LOG_LEVEL,
                    format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("frontend")

app = Flask(__name__)


@app.get("/health")
def health():
    return {"status": "ok"}, 200


@app.get("/")
def index():
    """Liste des todos (ou résultat de recherche)."""
    q = request.args.get("q", "")
    try:
        if q:
            r = requests.get(f"{BACKEND_URL}/api/search", params={"q": q}, timeout=5)
        else:
            r = requests.get(f"{BACKEND_URL}/api/todos", timeout=5)
        todos = r.json()
    except Exception as e:
        log.error("backend injoignable: %s", e)
        todos, q = [], q
    return render_template("index.html", todos=todos, q=q, backend=BACKEND_URL)


@app.post("/add")
def add():
    title = request.form.get("title", "")
    try:
        requests.post(f"{BACKEND_URL}/api/todos", json={"title": title}, timeout=5)
    except Exception as e:
        log.error("ajout KO: %s", e)
    return redirect(url_for("index"))


@app.post("/delete/<tid>")
def delete(tid):
    try:
        requests.delete(f"{BACKEND_URL}/api/todos/{tid}", timeout=5)
    except Exception as e:
        log.error("suppression KO: %s", e)
    return redirect(url_for("index"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=APP_PORT)
