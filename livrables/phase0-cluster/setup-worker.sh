#!/usr/bin/env bash
#
# Phase 0 - Mise en place du worker simulé (conforme fiche TP1)
# -------------------------------------------------------------
# Sur une seule machine, k3s-server fait par défaut AUSSI office de worker
# (kubelet sur 10250). Pour ajouter un k3s-agent sur le MÊME hôte sans
# collision de port, on bascule le server en control-plane pur
# (disable-agent), ce qui libère 10250/10256 pour l'agent.
#
# À lancer en root :   sudo bash setup-worker.sh
#
set -euo pipefail

SERVER_IP="192.168.30.150"          # INTERNAL-IP du node (kubectl get nodes -o wide)
K3S_VERSION="v1.34.6+k3s1"          # on épingle la version = celle du server
CONFIG="/etc/rancher/k3s/config.yaml"

echo "==> [1/5] Bascule du server en control-plane pur (disable-agent)"
mkdir -p /etc/rancher/k3s
if [ -f "$CONFIG" ] && grep -q '^disable-agent:' "$CONFIG"; then
  echo "    disable-agent déjà présent dans $CONFIG"
else
  echo "disable-agent: true" >> "$CONFIG"
  echo "    ajouté 'disable-agent: true' dans $CONFIG"
fi

echo "==> [2/5] Redémarrage du service k3s"
systemctl restart k3s
sleep 8

echo "==> [3/5] Attente que l'API server soit prête"
until k3s kubectl get --raw='/readyz' >/dev/null 2>&1; do
  printf '.'; sleep 2
done
echo " OK"

echo "==> [4/5] Nettoyage de l'ancien enregistrement du node 'kali' (devenu NotReady)"
k3s kubectl delete node kali --ignore-not-found

echo "==> [5/5] Installation du worker simulé (k3s-agent / worker1, LB port 6445)"
TOKEN="$(cat /var/lib/rancher/k3s/server/node-token)"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  K3S_URL="https://${SERVER_IP}:6443" \
  K3S_TOKEN="${TOKEN}" \
  sh -s - agent \
    --node-name worker1 \
    --lb-server-port 6445

echo
echo "==> Vérification (laisse ~15s aux pods système pour se replanifier)"
sleep 12
echo "--- Nodes ---"
k3s kubectl get nodes -o wide
echo "--- Services systemd ---"
systemctl is-active k3s && echo "k3s (server)  : active"
systemctl is-active k3s-agent && echo "k3s-agent     : active"
echo "--- Ports (séparation server/agent) ---"
ss -lntp | egrep ':6443|:6444|:6445|:10250' || true
echo
echo "Terminé. Attendu : 1 node 'worker1' Ready, ports 6443/6444 (server) + 6445/10250 (agent)."
