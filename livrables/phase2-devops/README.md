# Phase 2 — DEVOPS : automatiser, observer et corriger

> Projet DevSecOps ESAIP — TP3 (Jour 2). Objectif : industrialiser la Todo App
> via une chaîne **CI/CD**, **observer** le système, et **analyser un incident**
> sur une application volontairement vulnérable (DVWA). La correction des failles
> est traitée en **Phase 3 (TP4)**.

---

## 1. Architecture de la Phase 2

```
   Développeur
       │ git push
       ▼
 ┌─────────────────────────┐
 │  GitHub (repo PUBLIC)    │  ← POINT DE VÉRITÉ (code + manifests + CI)
 │  devsecops-projet-esaip  │
 └───────┬─────────────┬────┘
         │             │
   (CI)  ▼             ▼  (CD - GitOps pull)
 GitHub Actions     ArgoCD (dans k3s)
 lint→test→build    surveille livrables/phase1-dev/k8s
 →scan Trivy→push   et synchronise le cluster
         │             │
         ▼             ▼
   GHCR (registry)  ┌───────────────── k3s (worker1) ─────────────────┐
   todo-backend     │ ns todo-app : frontend → backend → PostgreSQL    │
   todo-frontend    │ ns lab      : DVWA + SA permissif + secret  ◄─ incident
                    │ ns argocd   : ArgoCD                              │
                    └─────────────────────────────────────────────────┘
```

Deux ensembles cohabitent :
- la **Todo App** (`todo-app`) = l'application industrialisée par la CI/CD ;
- le **bloc incident** (`lab`) = DVWA volontairement vulnérable, cible de l'attaque analysée.

---

## 2. Étape 0 — Environnement vulnérable + scénario d'incident

Fichiers : `lab/00-namespace.yaml`, `lab/10-rbac.yaml`, `lab/20-dvwa.yaml`,
`lab/30-secret.yaml`, et `incident-attack.sh`.

Déploiement : `kubectl apply -f lab/`

Le pod **DVWA** tourne avec le ServiceAccount `app2-sa`, lié à un **Role permissif**
(`get/list` sur `pods` ET `secrets`). Son token est auto-monté. Un secret `db-secret`
(`admin` / `SuperPassword123`) est présent dans le namespace.

**Scénario d'attaque** (`bash incident-attack.sh`, sortie réelle) :

```
==> [1] Token du ServiceAccount auto-monté récupéré (1172 caractères)
==> [2] Appel SANS token -> HTTP/1.0 401 Unauthorized
==> [3] Appel AVEC token -> HTTP/1.0 200 OK   - secret: db-secret
==> [4] Exfiltration db-secret -> password=SuperPassword123 | username=admin
```

Chaîne démontrée : **pod compromis → token SA → RBAC trop permissif → abus de
l'API Kubernetes → exfiltration + décodage d'un secret**.

> Remarque technique : l'image DVWA (Debian 9) n'embarque pas `curl` ; le script
> utilise `php` (présent car DVWA est une appli PHP) pour interroger l'API. L'attaque
> ne dépend que d'outils déjà dans le conteneur.

---

## 3. Étape 1 — CI (GitHub Actions)

Fichier : `.github/workflows/ci.yml`. Déclenchée à chaque `push`/PR.

| Étape | Outil | Détail |
|---|---|---|
| **lint** | flake8 | erreurs réelles bloquantes, style informatif |
| **test** | pytest | 4 tests frontend + 5 tests backend (sans DB réelle : mocks) |
| **build** | docker buildx | une image par service |
| **scan** | Trivy | HIGH/CRITICAL — **non bloquant en Phase 2** (deviendra bloquant en Phase 3) |
| **push** | GHCR | tags **SHA** (immuable) **+ latest** |

Résultat réel : pipeline **vert**, images publiées
`ghcr.io/dami-lowdev/todo-backend` et `todo-frontend` (tags `<sha>` + `latest`).

Pièges rencontrés et résolus : scope `workflow` requis sur le token pour pousser
`.github/workflows/` ; version `trivy-action@0.24.0` inexistante ; installeur binaire
de Trivy rate-limité par GitHub → remplacé par une install via le **dépôt apt officiel**
+ `continue-on-error`.

---

## 4. Étape 2 — CD (ArgoCD, GitOps)

Fichiers : `argocd/install-argocd.sh`, `argocd/application-todo.yaml`.

ArgoCD (installé allégé : Dex/ApplicationSet/Notifications désactivés) surveille le
dossier `livrables/phase1-dev/k8s` du repo et **synchronise automatiquement** le cluster
(`automated`, `prune`, `selfHeal`). Les manifests pointent désormais vers les images
**GHCR** (et non plus les images locales importées dans containerd en Phase 1).

Preuve réelle de fonctionnement :

| Vérification | Résultat |
|---|---|
| Pods Todo App | `READY 1/1`, 0 restart, images `ghcr.io/dami-lowdev/...:latest` |
| Révision déployée par ArgoCD | = dernier commit `main` (`c5c8aeb…`) |
| Application | `Synced / Healthy` |
| App accessible | `http://192.168.30.150:30080` → HTTP 200 |

Flux complet : **`git push` → ArgoCD détecte la dérive → sync → déploiement des images GHCR**.

---

## 5. Étape 3 — Observabilité et analyse de l'incident

Script : `observe.sh`. Les 3 axes demandés, avec données réelles :

1. **Logs applicatifs** — une injection SQL apparaît dans les logs verbeux du backend :
   `SQL search: SELECT id,title,done FROM todos WHERE title LIKE '%' OR '1'='1%'` → **détectable**.
2. **Logs du pod DVWA** — uniquement les logs Apache ; l'abus d'API **n'y figure pas**.
3. **Événements Kubernetes** (`kubectl get events -n lab`) — **aucun** : `exec` et appels API
   ne génèrent pas d'événement.
4. **Métriques** (`kubectl top`) — aucun pic : l'exfiltration d'un secret est trop légère.

**Bilan détection :**

| Comportement | Détecté par défaut ? |
|---|---|
| Tentative d'injection SQL | ✅ oui (logs verbeux) |
| `exec` dans un pod | ❌ non |
| Abus de l'API K8s / lecture de secrets via token SA | ❌ non |

➡️ L'incident principal (exfiltration via token SA) est **quasi invisible** avec
l'observabilité par défaut. Il faut l'**audit log de l'API server** et/ou un outil de
**runtime security (Falco)** — mis en place en **Phase 3**. C'est l'illustration directe
de la **défense en profondeur**.

---

## 6. Réponses aux questions (Phase 2)

### A) Observation de l'industrialisation (CI/CD)

**1. Quels éléments sont désormais versionnés ?**
- **code applicatif** : ✅ oui (dans le repo)
- **image Docker** : ✅ oui — via le registry GHCR, taguée par SHA (le *manifeste* de
  build est versionné, l'artefact est tracé par digest)
- **RBAC** : ✅ oui (`lab/10-rbac.yaml`)
- **secrets** : ⚠️ oui mais **en clair** dans Git (`lab/30-secret.yaml`) — c'est une
  **faille** (à corriger en Phase 3 : SOPS/Sealed Secrets, chiffrement at-rest)
- **NetworkPolicies** : ❌ non (absentes — ajoutées en Phase 3)

**2. Où se situe le point de vérité ?** Le **repository Git**. Avec ArgoCD (GitOps),
le cluster est un *reflet* de Git : toute dérive est corrigée (`selfHeal`). Le cluster
n'est plus la source mais la cible.

**3. Quelles étapes composent le pipeline CI ?** **build** ✅, **tests** ✅ (pytest),
**scan** ✅ (Trivy, non bloquant), **push** ✅ (GHCR). + lint (flake8) en amont.

**4. Rôle du registry ?** Stocker et distribuer les images construites par la CI.
Il découple le *build* (CI) du *run* (cluster) : le cluster ne build pas, il **tire**
une image immuable déjà testée et scannée. C'est le point de rendez-vous entre CI et CD.

**5. `latest` vs SHA ?** `latest` est un tag **mouvant** : il pointe vers une image qui
change dans le temps → non reproductible, on ne sait pas ce qui tourne réellement.
Un tag **par SHA/digest** est **immuable** : il identifie un contenu exact → traçabilité,
rollback fiable, reproductibilité. Bonne pratique : déployer par SHA. (Notre démo utilise
`latest` pour la simplicité, mais la CI produit aussi le tag SHA, qu'on épinglerait en prod.)

### B) Surface d'attaque après automatisation

1. **Le Role permissif est-il toujours dans les manifests versionnés ?** ✅ Oui
   (`lab/10-rbac.yaml`) — l'automatisation a *figé* la faille dans Git telle quelle.
2. **Le ServiceAccount est-il toujours monté automatiquement ?** ✅ Oui (comportement
   par défaut, non désactivé).
3. **Les secrets sont-ils toujours accessibles via l'API ?** ✅ Oui — le Role autorise
   `get/list secrets`, donc le token du pod y accède (démontré).
4. **Une NetworkPolicy par défaut ?** ❌ Non — tout pod peut joindre l'API server et les
   autres pods.
5. **L'API Kubernetes est-elle toujours accessible depuis le pod ?** ✅ Oui
   (`https://kubernetes.default.svc` joignable depuis DVWA).

> Conclusion B : automatiser une configuration **ne la sécurise pas** — au contraire,
> ça **reproduit la faille de façon fiable et systématique** à chaque déploiement.

### C) Lecture critique de l'incident

1. **Quels logs montrent l'accès à l'API K8s ?** Par défaut **aucun** côté cluster.
   Il faudrait activer l'**audit log de l'API server** (non actif par défaut sur k3s).
   Côté pod, l'appel sortant n'est pas logué.
2. **Quels événements montrent un `exec` ?** **Aucun** `kubectl get events`. Un `exec`
   passe par l'API server ; seul l'audit log le tracerait.
3. **Comment identifier une lecture répétée de secrets ?** Uniquement via l'**audit log**
   (verbe `get`/`list` sur `secrets` par le SA `app2-sa`) ou un outil runtime (Falco).
4. **Une hausse des appels API est-elle visible dans les métriques ?** Pas dans
   `kubectl top` (CPU/mémoire). Les métriques de l'API server (`apiserver_request_total`)
   le montreraient, mais ne sont pas exposées par défaut ici.
5. **Le comportement anormal est-il détecté automatiquement ?** ❌ **Non.** C'est le
   constat central : sans audit/runtime security, l'exfiltration passe inaperçue.

### D) Lien entre CI/CD et sécurité cluster

1. **Comment la CI aurait pu empêcher DVWA ?** Un **scan d'image bloquant** (Trivy en
   `--exit-code 1`) aurait refusé une image notoirement vulnérable ; une **policy**
   (ex. Conftest/OPA sur les manifests) aurait rejeté `image: vulnerables/web-dvwa`.
2. **Comment le CD aurait pu empêcher un RBAC permissif ?** Un **admission controller**
   (OPA Gatekeeper/Kyverno) en amont du déploiement aurait refusé un Role donnant
   `secrets: get,list`, ou un SA monté inutilement.
3. **Quelle couche aurait dû bloquer l'accès aux secrets ?** Le **RBAC** (least privilege :
   retirer `secrets`) **et** la désactivation de l'`automountServiceAccountToken`.
4. **Impact d'un commit malveillant dans un repo GitOps ?** Comme Git pilote le cluster,
   un commit malveillant est **déployé automatiquement** par ArgoCD → le repo devient une
   cible critique (d'où : revue de code, branches protégées, commits signés, RBAC Git).
5. **Pourquoi un pipeline compromis est-il critique ?** Il a les **droits de pousser des
   images et de déployer** : le compromettre = exécuter du code arbitraire en production,
   contourner tous les contrôles en aval (supply-chain attack).

### E) Analyse critique globale

1. **Automatiser vs sécuriser un système automatisé ?** *Automatiser* = rendre le
   déploiement rapide, reproductible, sans intervention humaine. *Sécuriser l'automatisé*
   = s'assurer que cette mécanique ne **propage** pas de failles et qu'elle est elle-même
   protégée (pipeline, registry, repo, RBAC). Automatiser une faille la rend **systématique**.
2. **Faille fondamentale exploitée ?** L'**excès de privilèges** : un ServiceAccount
   monté par défaut + un RBAC trop permissif (`secrets: get/list`). Violation du
   **moindre privilège**.
3. **UNE mesure prioritaire ?** Le **RBAC strict** (retirer l'accès aux secrets) — c'est
   la cause racine de l'exfiltration. *(la désactivation du token auto-mount est un second
   rempart immédiat ; le scan CI et la NetworkPolicy complètent la défense en profondeur.)*
4. **Pourquoi la sécurité dès la conception ?** Rajouter la sécurité après coup coûte cher
   et laisse des fenêtres d'exposition. Ici, l'automatisation a *gravé* les failles dans
   Git et les a déployées en boucle : il aurait fallu les contrôles (scan, RBAC, policies)
   **dès** la définition des manifests (*shift-left*).
5. **En quoi est-ce de la défense en profondeur ?** Aucune mesure unique ne suffit :
   RBAC strict **+** token non monté **+** NetworkPolicy **+** scan CI **+** audit/runtime
   forment des **couches** indépendantes ; l'attaquant doit toutes les franchir.

### F) Raisonnement architecture

1. **Risque si plusieurs namespaces ont la même config ?** La faille est **répliquée** :
   compromettre un pod dans n'importe quel namespace donne le même accès aux secrets →
   surface d'attaque multipliée, mouvement latéral facilité.
2. **Vers un multi-tenant sécurisé ?** Isolation par namespace **avec** RBAC dédié par
   tenant, NetworkPolicies par défaut `deny-all`, quotas de ressources, SA distincts sans
   token auto-monté, et idéalement séparation des nœuds/clusters pour les tenants sensibles.
3. **Quelle couche manque encore ?** Les quatre : **chiffrement des secrets at-rest**,
   **admission controller** (Kyverno/OPA), **runtime security** (Falco), **isolation réseau
   avancée** (NetworkPolicies). → feuille de route de la **Phase 3**.
4. **Prochaine étape de l'attaquant après l'exfiltration ?** Réutiliser les identifiants
   (`admin`/`SuperPassword123`) pour un **mouvement latéral** (accès à la base / à d'autres
   services), recherche d'autres secrets/tokens, escalade vers le node ou le control-plane,
   puis **persistance**.

---

## 7. Comment rejouer la Phase 2

```bash
# 0) bloc incident
kubectl apply -f lab/
bash incident-attack.sh           # démontre l'exfiltration

# 1) CI : automatique à chaque push (voir onglet Actions du repo)

# 2) CD : installer ArgoCD + déclarer l'Application
bash argocd/install-argocd.sh
kubectl -n argocd get application todo-app   # -> Synced / Healthy

# 3) observabilité
bash observe.sh
```
