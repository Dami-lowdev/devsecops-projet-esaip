"""
APP2 — Backend API de la Todo App (Flask + PostgreSQL).

Service "métier" : il expose une API REST et accède à la base de données.
C'est le service ciblé par l'incident simulé de la Phase 2.

⚠️  PHASE 1 = aucune sécurité avancée (consigne de l'énoncé).
    Les faiblesses VOLONTAIRES sont balisées par  # [VULN]  pour être
    analysées (surface d'attaque) puis corrigées en Phase 3.
"""
import os
import logging
import psycopg2
from flask import Flask, request, jsonify

# --- Configuration par variables d'environnement -------------------------
DB_HOST = os.environ.get("DB_HOST", "todo-db")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "todos")
DB_USER = os.environ.get("DB_USER", "todo")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "todo")     # secret applicatif
APP_PORT = int(os.environ.get("APP_PORT", "5000"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "DEBUG")        # [VULN] DEBUG par défaut

# [VULN] logs trop verbeux : on logue toute la config, secret DB inclus
logging.basicConfig(level=LOG_LEVEL,
                    format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("backend")
log.info("Démarrage backend avec config: host=%s db=%s user=%s password=%s",
        DB_HOST, DB_NAME, DB_USER, DB_PASSWORD)   # [VULN] secret dans les logs

app = Flask(__name__)


def db():
    """Connexion PostgreSQL (nouvelle connexion par requête, simple)."""
    return psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
                            user=DB_USER, password=DB_PASSWORD)


def init_schema():
    """Crée la table si absente + un jeu de données de démo."""
    conn = db()
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS todos (
            id         SERIAL PRIMARY KEY,
            title      TEXT NOT NULL,
            done       BOOLEAN NOT NULL DEFAULT FALSE,
            created_at TIMESTAMP NOT NULL DEFAULT NOW()
        );
    """)
    cur.execute("SELECT COUNT(*) FROM todos;")
    if cur.fetchone()[0] == 0:
        cur.execute("INSERT INTO todos (title) VALUES "
                    "('Acheter du pain'), ('Réviser DevSecOps'), ('Sécuriser le cluster');")
    conn.commit()
    cur.close()
    conn.close()


# --- Endpoints REST -------------------------------------------------------

@app.get("/health")
def health():
    """Sonde de vivacité (utilisée par Kubernetes)."""
    try:
        conn = db(); conn.close()
        return jsonify(status="ok"), 200
    except Exception as e:
        log.error("health KO: %s", e)
        return jsonify(status="error", detail=str(e)), 500


@app.get("/api/todos")
def list_todos():
    conn = db(); cur = conn.cursor()
    cur.execute("SELECT id, title, done, created_at FROM todos ORDER BY id;")
    rows = cur.fetchall()
    cur.close(); conn.close()
    return jsonify([
        {"id": r[0], "title": r[1], "done": r[2], "created_at": str(r[3])}
        for r in rows
    ])


@app.post("/api/todos")
def create_todo():
    data = request.get_json(force=True, silent=True) or {}
    title = data.get("title", "")
    # [VULN] injection SQL : titre concaténé directement dans la requête
    sql = f"INSERT INTO todos (title) VALUES ('{title}') RETURNING id;"
    log.debug("SQL create: %s", sql)              # [VULN] requête loguée
    conn = db(); cur = conn.cursor()
    cur.execute(sql)
    new_id = cur.fetchone()[0]
    conn.commit(); cur.close(); conn.close()
    return jsonify(id=new_id, title=title), 201


@app.delete("/api/todos/<tid>")
def delete_todo(tid):
    # [VULN] injection SQL : identifiant non paramétré
    sql = f"DELETE FROM todos WHERE id = {tid};"
    log.debug("SQL delete: %s", sql)
    conn = db(); cur = conn.cursor()
    cur.execute(sql)
    conn.commit(); cur.close(); conn.close()
    return jsonify(deleted=tid)


@app.get("/api/search")
def search_todos():
    q = request.args.get("q", "")
    # [VULN] injection SQL classique via le paramètre de recherche
    sql = f"SELECT id, title, done FROM todos WHERE title LIKE '%{q}%';"
    log.debug("SQL search: %s", sql)
    conn = db(); cur = conn.cursor()
    cur.execute(sql)
    rows = cur.fetchall()
    cur.close(); conn.close()
    return jsonify([{"id": r[0], "title": r[1], "done": r[2]} for r in rows])


@app.get("/api/debug")
def debug():
    # [VULN] endpoint de debug qui expose TOUTES les variables d'environnement
    # (donc les secrets) — typique d'une fuite d'information.
    return jsonify(dict(os.environ))


if __name__ == "__main__":
    try:
        init_schema()
    except Exception as e:
        log.error("init schema KO (la DB n'est peut-être pas prête): %s", e)
    # [VULN] debug=True en production : expose le debugger Werkzeug (RCE possible)
    app.run(host="0.0.0.0", port=APP_PORT, debug=True)
