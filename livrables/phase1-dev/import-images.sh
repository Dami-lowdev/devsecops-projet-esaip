#!/usr/bin/env bash
#
# Phase 1 - Import des images locales dans le containerd de k3s (worker1)
# ----------------------------------------------------------------------
# k3s n'utilise pas le daemon Docker mais containerd. On importe donc les
# images buildées avec Docker dans le containerd de k3s.
#
# À lancer en root :  sudo bash import-images.sh
#
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Import todo-backend:1.0"
k3s ctr images import images/todo-backend-1.0.tar

echo "==> Import todo-frontend:1.0"
k3s ctr images import images/todo-frontend-1.0.tar

echo "==> Vérification (images todo-* présentes dans containerd)"
k3s ctr images ls | grep -E 'todo-backend|todo-frontend' || true

echo
echo "Import terminé. Tu peux supprimer les .tar pour libérer ~2 Go :"
echo "    rm -f images/todo-backend-1.0.tar images/todo-frontend-1.0.tar"
