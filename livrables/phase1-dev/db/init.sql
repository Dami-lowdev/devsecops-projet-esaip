-- DB — Schéma initial de la Todo App (PostgreSQL)
-- Exécuté automatiquement au 1er démarrage du conteneur postgres
-- (monté dans /docker-entrypoint-initdb.d/).

CREATE TABLE IF NOT EXISTS todos (
    id         SERIAL PRIMARY KEY,
    title      TEXT NOT NULL,
    done       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

INSERT INTO todos (title) VALUES
    ('Acheter du pain'),
    ('Réviser DevSecOps'),
    ('Sécuriser le cluster');
