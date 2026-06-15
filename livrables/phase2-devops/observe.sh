#!/usr/bin/env bash
#
# Phase 2 - Etape 3 : observabilité (logs / événements / métriques)
# -----------------------------------------------------------------
# Donne une vue des 3 axes d'observabilité de base et cherche les
# comportements anormaux liés au scénario d'incident.
#
# Usage :  bash observe.sh
set -uo pipefail

line(){ printf '\n──────────── %s ────────────\n' "$1"; }

line "1. LOGS APPLICATIFS — backend Todo (APP2) : trace d'une injection SQL"
# On déclenche une injection SQL classique sur la recherche, puis on lit le log.
# Les logs DEBUG [VULN] loguent la requête SQL -> l'attaque est visible ici.
curl -s "http://192.168.30.150:30080/?q=%27%20OR%20%271%27%3D%271" -o /dev/null || true
kubectl -n todo-app logs deploy/todo-backend --tail=8 2>/dev/null \
  | grep -iE "SQL|LIKE|OR '1'" || echo "(pas de ligne SQL trouvée — relance après une requête)"

line "2. LOGS — pod DVWA (cible de l'incident) côté serveur"
# Le pod DVWA ne logue PAS ses appels sortants vers l'API K8s : l'exfiltration
# n'apparaît pas dans les logs applicatifs du conteneur.
POD=$(kubectl get pod -n lab -l app=app2-dvwa -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl -n lab logs "$POD" --tail=5 2>/dev/null | sed 's/^/   /' || echo "   (pas de logs)"
echo "   => L'abus d'API (token SA -> lecture de secrets) n'y figure PAS."

line "3. ÉVÉNEMENTS KUBERNETES (namespace lab)"
kubectl -n lab get events --sort-by=.lastTimestamp 2>/dev/null | tail -10
echo "   => 'kubectl exec' et les appels API ne génèrent AUCUN événement par défaut."

line "4. MÉTRIQUES DE BASE (consommation par pod)"
kubectl top pods -A 2>/dev/null | grep -E "NAME|todo-|app2-dvwa|argocd-server" || echo "(metrics-server indisponible)"
echo "   => L'exfiltration d'un secret est légère : aucun pic visible dans les métriques."

line "BILAN détection"
cat <<'EOF'
  Détectable avec l'observabilité par défaut :
    - tentative d'injection SQL  -> OUI (logs verbeux du backend)
  NON détectable par défaut :
    - exec dans un pod           -> NON (pas d'événement)
    - abus de l'API K8s / lecture de secrets via token SA -> NON
      (nécessite l'audit log de l'API server et/ou un outil runtime
       comme Falco -> mis en place en Phase 3 = défense en profondeur)
EOF
