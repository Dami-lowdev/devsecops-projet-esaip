#!/usr/bin/env bash
#
# Phase 2 - Etape 2 : installation d'ArgoCD (CD GitOps) sur k3s.
# ---------------------------------------------------------------
# Installe ArgoCD dans le namespace `argocd`, allège l'empreinte mémoire
# (composants non nécessaires retirés pour tenir sur une Kali ~4 Go),
# puis déclare l'Application qui synchronise la Todo App depuis Git.
#
# Usage :  bash install-argocd.sh
set -euo pipefail
cd "$(dirname "$0")"

ARGOCD_VERSION="v2.13.2"

echo "==> 1) Namespace argocd"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "==> 2) Installation d'ArgoCD ($ARGOCD_VERSION)"
kubectl apply -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> 3) Allègement mémoire (composants non requis pour ce TP)"
# Dex (SSO), ApplicationSet et Notifications ne sont pas utiles ici.
kubectl -n argocd scale deploy argocd-dex-server --replicas=0 2>/dev/null || true
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0 2>/dev/null || true
kubectl -n argocd scale deploy argocd-notifications-controller --replicas=0 2>/dev/null || true

echo "==> 4) Attente que le serveur ArgoCD soit prêt"
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

echo "==> 5) Déclaration de l'Application todo-app (sync auto depuis Git)"
kubectl apply -f application-todo.yaml

cat <<'EOF'

ArgoCD installé.

Mot de passe admin initial :
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d ; echo

Accès UI (port-forward) :
  kubectl -n argocd port-forward svc/argocd-server 8081:443
  -> https://localhost:8081   (user: admin)

Etat de la synchro :
  kubectl -n argocd get applications
EOF
