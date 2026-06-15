# APP2 — Backend API
# PHASE 1 : aucun durcissement (utilisateur root autorisé par la consigne).
# [VULN] image basée sur une variante complète, exécution en root, pas de USER.
#        Sera durci en Phase 3 (image slim, USER non-root, etc.).
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 5000

# [VULN] le conteneur tourne en root (aucune directive USER)
CMD ["python", "app.py"]
