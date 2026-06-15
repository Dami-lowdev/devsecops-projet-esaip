#!/usr/bin/env bash
#
# Phase 0 - Correctif worker simulé
# ---------------------------------
# Problème : server et agent lisent le MÊME /etc/rancher/k3s/config.yaml.
# Ce fichier contient 'disable-agent: true' (option SERVER uniquement) ->
# l'agent plante : "flag provided but not defined: -disable-agent".
#
# Solution : donner à l'agent un fichier de config dédié via --config,
# pour qu'il ne lise plus le config.yaml du server.
#
# À lancer en root :  sudo bash fix-worker.sh
#
set -euo pipefail

AGENT_CFG="/etc/rancher/k3s/config-agent.yaml"
UNIT="/etc/systemd/system/k3s-agent.service"

echo "==> [1/4] Création de la config dédiée à l'agent : $AGENT_CFG"
cat > "$AGENT_CFG" <<'EOF'
# Config dédiée au worker simulé (ne lit PAS le config.yaml du server)
node-name: worker1
lb-server-port: 6445
EOF

echo "==> [2/4] Ajout de '--config $AGENT_CFG' à l'ExecStart de l'agent (si absent)"
if grep -q 'config-agent.yaml' "$UNIT"; then
  echo "    déjà présent."
else
  # insère les deux lignes d'argument juste après la ligne '    agent \'
  sed -i "/^    agent \\\\$/a\\	'--config' \\\\\n	'$AGENT_CFG' \\\\" "$UNIT"
fi

echo "==> [3/4] Rechargement systemd + redémarrage de l'agent"
systemctl daemon-reload
systemctl restart k3s-agent

echo "==> [4/4] Vérification (laisse ~15s aux pods système de se replanifier)"
sleep 14
echo "--- ExecStart agent ---"
sed -n '/^ExecStart=/,/[^\\]$/p' "$UNIT"
echo "--- Nodes ---"
k3s kubectl get nodes -o wide
echo "--- Services ---"
echo "k3s       : $(systemctl is-active k3s)"
echo "k3s-agent : $(systemctl is-active k3s-agent)"
echo "--- Ports (séparation server/agent) ---"
ss -lntp | egrep ':6443|:6444|:6445|:10250' || true
echo
echo "Attendu : worker1 Ready, k3s-agent active, 6443/6444 (server) + 6445/10250 (agent)."
