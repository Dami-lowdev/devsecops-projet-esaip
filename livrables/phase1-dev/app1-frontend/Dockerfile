# APP1 — Frontend
# PHASE 1 : aucun durcissement (utilisateur root autorisé par la consigne).
# [VULN] exécution en root, pas de USER, image complète. Durci en Phase 3.
FROM python:3.12

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates/ templates/

EXPOSE 8080

CMD ["python", "app.py"]
