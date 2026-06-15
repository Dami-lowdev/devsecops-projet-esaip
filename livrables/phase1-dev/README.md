# Phase 1 — DEV : construire et comprendre la surface d'attaque

> Objectif : concevoir une application micro-services (Todo App), la conteneuriser,
> la déployer sur k3s, et **comprendre où se situent les risques**.
> Stack : **Flask** (APP1 frontend, APP2 backend) + **PostgreSQL** (DB).

---

## Étape 1 — Architecture applicative

### 1.1 Schéma d'architecture logique

```
                          UTILISATEUR (navigateur)
                                   │
                                   │  HTTP  (port 30080 NodePort -> 8080)
                                   ▼
   ┌───────────────────────────────────────────────────────────┐
   │ APP1 — FRONTEND (Flask)                  Service NodePort   │
   │  • sert l'UI HTML (templates/index.html)                    │
   │  • relaie les actions vers APP2 (server-side, requests)     │
   │  • SEUL composant exposé à l'utilisateur                    │
   └───────────────────────────────┬───────────────────────────┘
                                   │  REST / JSON  (HTTP :5000)
                                   │  GET/POST/DELETE /api/todos, /api/search
                                   ▼
   ┌───────────────────────────────────────────────────────────┐
   │ APP2 — BACKEND API (Flask)               Service ClusterIP  │
   │  • logique métier + accès base de données                  │
   │  • endpoints REST, logs applicatifs, config par env        │
   │  • CIBLE de l'incident simulé (Phase 2)                     │
   └───────────────────────────────┬───────────────────────────┘
                                   │  SQL  (TCP :5432)
                                   ▼
   ┌───────────────────────────────────────────────────────────┐
   │ DB — PostgreSQL 16                        Service ClusterIP  │
   │  • table `todos`                                            │
   │  • non exposée hors du cluster                              │
   └───────────────────────────────────────────────────────────┘
```

### 1.2 Description textuelle des flux

| # | Source → Destination | Protocole / Port | Rôle | Nécessaire ? |
|---|----------------------|------------------|------|--------------|
| F1 | Navigateur → APP1 | HTTP / 30080→8080 | Affichage UI, actions utilisateur | Oui (point d'entrée) |
| F2 | APP1 → APP2 | HTTP REST / 5000 | CRUD todos, recherche | Oui |
| F3 | APP2 → DB | SQL / 5432 | Lecture/écriture des tâches | Oui |
| F4 | APP2 → Internet | — | (aucun en théorie) | Non — à bloquer plus tard |

- **Points d'entrée utilisateur** : uniquement APP1 (NodePort 30080).
- **Dépendances** : APP1 dépend d'APP2 ; APP2 dépend de la DB. Si APP2 tombe,
  l'UI affiche une liste vide (dégradation contrôlée).
- **Données en transit** : titres de tâches (F1/F2), requêtes/réponses SQL (F3).
  À ce stade **aucun chiffrement** interne (HTTP en clair, SQL en clair).

### 1.3 Réponses — questions Étape 1

**1. Monolithique vs micro-services.**
Une architecture **monolithique** regroupe toutes les fonctions (UI, métier, accès
données) dans une seule application/déployable unique. Une architecture
**micro-services** découpe l'application en services indépendants, déployés et mis
à l'échelle séparément, communiquant par le réseau (API REST ici). Notre Todo App
est micro-services : 3 services (frontend, backend, DB) déployables indépendamment.

**2. Avantages / inconvénients des micro-services côté sécurité.**
*Avantages* : isolation (un service compromis ≠ tout le système), surface
réductible service par service, possibilité de **segmenter** le réseau et les
identités (NetworkPolicy, RBAC, ServiceAccount dédiés), principe du moindre
privilège applicable finement.
*Inconvénients* : **surface d'attaque réseau accrue** (chaque appel inter-service
est un flux à protéger), complexité de l'authentification service-à-service,
secrets multipliés, observabilité plus difficile, plus de composants à patcher.

**3. Composants exposés à l'utilisateur final.**
Uniquement **APP1 (frontend)** via le NodePort 30080. APP2 et la DB sont en
ClusterIP, donc **non joignables** depuis l'extérieur du cluster.

**4. Types de données entre les services.**
Titres de tâches (texte saisi par l'utilisateur), identifiants numériques,
requêtes/réponses JSON (F2), requêtes/résultats SQL (F3), et le **secret de
connexion à la DB** (variable d'environnement côté APP2).

**5. Incident réel — API backend compromise (résumé).**
*Optus (Australie, septembre 2022).* L'opérateur télécom Optus a subi l'une des
plus grandes fuites de données australiennes (~9,8 millions de clients). La cause
racine était une **API backend exposée sur Internet sans authentification** :
un endpoint REST destiné à un usage interne était accessible publiquement et
renvoyait des données clients à partir d'identifiants **séquentiels et
énumérables** (pas de contrôle d'accès, pas de rate-limiting). Un attaquant a pu
**itérer sur les identifiants** pour aspirer noms, dates de naissance, numéros de
passeport et de permis. L'incident illustre trois fautes classiques côté API :
absence d'authentification/autorisation (« Broken Object Level Authorization »,
top OWASP API Security), identifiants prévisibles, et exposition d'un service
backend qui aurait dû rester interne. Conséquences : enquête réglementaire,
coûts de réémission de pièces d'identité, atteinte réputationnelle majeure.
*Parallèle avec notre projet* : notre APP2 ne doit jamais être joignable
directement par l'utilisateur (d'où le ClusterIP) et devra appliquer validation
et contrôle d'accès.

---

## Étape 2 — Développement applicatif et vulnérabilités

### 2.1 Ce qui a été implémenté

- **APP2 backend** (`app2-backend/app.py`) : endpoints REST `GET /api/todos`,
  `POST /api/todos`, `DELETE /api/todos/<id>`, `GET /api/search`, `GET /health`,
  `GET /api/debug` ; logs applicatifs ; configuration par variables d'environnement.
- **APP1 frontend** (`app1-frontend/app.py`) : UI + relais des actions vers APP2.
- **Tests simples** réalisés (voir 2.3).

### 2.2 Vulnérabilités VOLONTAIRES (balisées `# [VULN]`)

| # | Faille | Emplacement | Démontrée |
|---|--------|-------------|-----------|
| V1 | **Injection SQL** (recherche, ajout, suppression : requêtes concaténées) | `app.py` create/delete/search | ✅ `?q=' OR '1'='1` renvoie toutes les lignes |
| V2 | **Fuite de secrets** : `/api/debug` dump tout `os.environ` | `app.py` debug() | ✅ `DB_PASSWORD=todo` exposé |
| V3 | **Logs verbeux** : secret DB et requêtes SQL loggés | `app.py` startup + debug | ✅ mot de passe en clair dans les logs |
| V4 | **`debug=True`** (debugger Werkzeug → RCE possible) | `app.py` main | présent |
| V5 | **Conteneur root**, image complète | `Dockerfile` | présent |
| V6 | **Secret en clair** dans le manifest (pas de Secret K8s) | `k8s/*.yaml` | présent |

### 2.3 Tests réalisés (preuves)

```
# Fonctionnel : GET /api/todos -> 3 tâches (Acheter du pain, Réviser DevSecOps, ...)
# Frontend HTML servi correctement via le NodePort
# V1 : /api/search?q=pain -> 1 ligne ; ?q=' OR '1'='1 -> 3 lignes (bypass du filtre)
# V2 : /api/debug -> DB_PASSWORD = todo
# V3 : logs backend -> "Démarrage backend avec config: ... password=todo"
```

### 2.4 Réponses — questions Étape 2

**1. Qu'est-ce qu'une vulnérabilité applicative ? 3 exemples.**
Une faiblesse dans le **code ou la conception** de l'application qu'un attaquant
peut exploiter. Exemples : (a) **injection SQL** (entrées non paramétrées) ;
(b) **XSS** (contenu utilisateur réinjecté sans échappement dans le HTML) ;
(c) **exposition de secrets** (mot de passe en clair dans le code/les logs/un
endpoint de debug). Les trois sont présentes ou possibles dans notre app.

**2. Pourquoi les APIs sont une cible privilégiée.**
Elles exposent directement la **logique métier et les données**, sont souvent
**accessibles à distance**, parfois **mal authentifiées/autorisées**, et leur
documentation/structure est prévisible. Elles permettent l'**automatisation** de
l'attaque (énumération, scraping massif) — cf. incident Optus.

**3. Logs trop verbeux = risque.**
Ils peuvent contenir des **secrets** (mots de passe, tokens), des **données
personnelles**, ou des **détails techniques** (requêtes SQL, versions, chemins)
qui facilitent une attaque. Un attaquant ayant accès aux logs obtient des
informations sensibles « gratuitement ». Notre V3 logge le mot de passe DB.

**4. Secret applicatif vs variable de configuration.**
Une **variable de configuration** paramètre le comportement (URL backend, niveau
de log, port) — non sensible. Un **secret** est une donnée confidentielle
(mot de passe DB, clé API, token) qui doit être **chiffrée, à accès restreint, et
jamais loggée ni commitée**. Le mot de passe DB est un secret ; `LOG_LEVEL` est
une config.

**5. Vulnérabilité célèbre liée à une mauvaise gestion des entrées utilisateur.**
*TalkTalk (Royaume-Uni, 2015).* Le fournisseur d'accès TalkTalk a été victime
d'une **injection SQL** exploitant un formulaire web dont les entrées n'étaient
pas filtrées/paramétrées. Les attaquants ont extrait les données de ~157 000
clients (coordonnées, certaines données bancaires). L'ICO a infligé une amende
record (£400 000) en soulignant que la faille était **connue et évitable**
(paramétrage des requêtes). C'est l'illustration directe de notre V1 : une entrée
utilisateur injectée telle quelle dans une requête SQL.

---

## Étape 3 — Conteneurisation

### 3.1 Dockerfiles
Un `Dockerfile` par service (`app1-frontend/`, `app2-backend/`), base
`python:3.12`, dépendances via `requirements.txt`, **aucun durcissement** (consigne).
Images buildées localement :

```
todo-backend:1.0    ~1.13 GB
todo-frontend:1.0   ~1.12 GB
```

> ⚠️ La **taille de ~1,1 Go** est elle-même un problème de sécurité (surface
> d'attaque) : image de base complète = beaucoup de paquets/outils inutiles donc
> plus de CVE potentielles. Sera réduite en Phase 3 (`slim`, multi-stage, non-root).

### 3.2 Réponses — questions Étape 3

**1. Rôle d'un conteneur en cloud-native.**
Empaqueter une application **avec ses dépendances** dans une unité **portable,
isolée et reproductible**, qui s'exécute de manière identique partout, démarre
vite et se prête à l'orchestration (Kubernetes).

**2. Image vs conteneur.**
Une **image** est un modèle **immuable** (couches en lecture seule) ; un
**conteneur** est une **instance en exécution** d'une image (avec une couche
inscriptible et un cycle de vie). Une image → plusieurs conteneurs.

**3. Pourquoi root dans un conteneur pose problème.**
Si un attaquant compromet le processus, il est **root dans le conteneur** ; en cas
de mauvaise isolation (capabilities, montages, kernel partagé), cela facilite une
**évasion de conteneur** vers l'hôte et l'escalade de privilèges. D'où l'exécution
**non-root** + suppression des capabilities (Phase 3).

**4. « Surface d'attaque » d'une image Docker.**
L'ensemble des éléments embarqués exploitables : paquets système et bibliothèques
(et leurs CVE), shells/outils présents, secrets éventuellement copiés dans les
couches, ports, configuration. Plus l'image est grosse, plus la surface est large.

**5. Vulnérabilité liée à une image Docker mal conçue.**
*Images malveillantes sur Docker Hub (campagne « docker123321 », 2017-2018).*
Des images publiques piégées (ex. faux serveurs populaires) embarquaient un
**mineur de cryptomonnaie** et/ou des **backdoors**. Cumulant des millions de
`docker pull`, elles s'exécutaient avec les privilèges de l'hôte hôte et minaient
du Monero. Autre classe fréquente : des images contenant des **secrets oubliés
dans une couche** (clé AWS, `.env`) — même supprimés dans une couche ultérieure,
ils restent **récupérables dans l'historique des couches**. Leçon : ne tirer que
des images de **confiance**, **scanner** les images (Trivy, Phase 3), et ne jamais
copier de secret dans une image.

---

## Étape 4 — Déploiement Kubernetes minimal

### 4.1 Manifests (`k8s/`)
- `00-namespace.yaml` : namespace `todo-app`
- `10-db.yaml` : ConfigMap (init.sql) + Deployment + Service ClusterIP (PostgreSQL)
- `20-backend.yaml` : Deployment + Service ClusterIP (APP2)
- `30-frontend.yaml` : Deployment + Service **NodePort 30080** (APP1)

ServiceAccount **par défaut**, **aucune NetworkPolicy** (conforme consigne).

### 4.2 Preuve de déploiement
```
$ kubectl -n todo-app get pods -o wide
NAME                  READY  STATUS   NODE
todo-backend-...      1/1    Running  worker1
todo-db-...           1/1    Running  worker1
todo-frontend-...     1/1    Running  worker1

$ kubectl -n todo-app get svc
todo-backend   ClusterIP  10.43.8.58     5000/TCP
todo-db        ClusterIP  10.43.207.164  5432/TCP
todo-frontend  NodePort   10.43.56.168   8080:30080/TCP
```
Application accessible : **http://192.168.30.150:30080** (UI fonctionnelle).

### 4.3 Réponses — questions Étape 4

**1. Rôle d'un Pod.**
Plus petite unité déployable de Kubernetes : un ou plusieurs conteneurs partageant
**réseau (IP) et volumes**, planifiés ensemble sur un node. Nos services tournent
chacun dans un pod.

**2. Pourquoi K8s n'est pas « sécurisé par défaut ».**
K8s privilégie la **flexibilité et le fonctionnement** : réseau **plat** (tous les
pods se parlent), **pas de NetworkPolicy**, RBAC large, token de ServiceAccount
monté automatiquement, secrets non chiffrés. La sécurité est un **choix à
configurer** (modèle « opt-in »).

**3. Ce que permet le ServiceAccount par défaut.**
Chaque pod reçoit le token du SA `default`, **monté automatiquement** dans
`/var/run/secrets/...`. Ce token authentifie le pod auprès de l'API server ; selon
le RBAC, il peut permettre de **lire des ressources** voire plus. Volé, il devient
un point d'entrée vers l'API.

**4. Risques d'un cluster sans NetworkPolicy.**
Réseau **plat** : un pod compromis peut **joindre tous les autres services** (DB,
APIs, API server), scanner le réseau interne, et **exfiltrer** vers Internet.
Aucune segmentation = mouvement latéral facile.

**5. Attaque réelle exploitant une mauvaise config Kubernetes.**
*Tesla (2018, découverte par RedLock).* Des attaquants ont trouvé un **dashboard
Kubernetes exposé sur Internet sans authentification**. Via la console, ils ont
accédé aux pods et y ont **récupéré des identifiants AWS** stockés en clair, puis
déployé un **cryptominer** (Monero) dans le cluster — en prenant soin de le cacher
derrière CloudFlare et de limiter l'usage CPU pour rester discret. Causes :
**console d'admin non protégée**, **secrets en clair**, **absence de segmentation
et de détection**. C'est le scénario type que notre projet cherche à prévenir :
exposition + secrets faibles + pas de contrôle réseau/runtime.

---

## Réponses — PDF Questions, parties D et E (lien app ↔ infrastructure)

### D) Lien entre application et infrastructure

**1. Composants exposés à l'utilisateur final** : APP1 (frontend) via NodePort
30080. Tout le reste est interne (ClusterIP).

**2. Flux strictement nécessaires** : F1 (user→APP1), F2 (APP1→APP2:5000),
F3 (APP2→DB:5432). Rien d'autre n'est requis.

**3. Flux implicitement autorisés mais non justifiés** : à cause du réseau plat
(pas de NetworkPolicy), sont **aussi** permis sans justification :
user/pods → DB directement, APP1 → DB, n'importe quel pod → APP2, et tout pod →
Internet, ainsi que tout pod → API server. Ce sont ces flux qu'on supprimera en
Phase 3 (deny-all + autorisations explicites).

**4. Comment une vulnérabilité applicative devient une menace cluster.**
Une SQLi (V1) ou le debugger Werkzeug (V4) peut donner une **exécution de code
dans le pod APP2**. À partir de là, l'attaquant lit le **token du ServiceAccount**,
interroge l'API, et — faute de NetworkPolicy/RBAC — **rebondit** vers la DB et les
autres services. La faille applicative devient un **point de pivot** vers
l'infrastructure.

**5. Pourquoi une simple API compromise peut mener à un incident majeur.**
Parce que l'API (APP2) a accès à la DB (donc aux données) **et** s'exécute dans le
cluster avec un token et un réseau ouverts. Une compromission ne se limite pas à
APP2 : elle ouvre la voie au **vol de données** (DB) et au **mouvement latéral**
(cluster). L'impact est démultiplié par l'environnement, pas seulement par la faille.

### E) Raisonnement DevSecOps — synthèse

**1. Sécuriser un composant vs sécuriser un système.**
Sécuriser un **composant** = durcir une brique isolée (ex. paramétrer les requêtes
SQL d'APP2). Sécuriser un **système** = raisonner sur **l'ensemble et ses
interactions** : flux réseau, identités, secrets, runtime, chaîne CI/CD — en
**défense en profondeur**, pour que la défaillance d'un composant ne compromette
pas le tout.

**2. Première mesure de sécurité prioritaire.**
La **segmentation réseau par NetworkPolicy en `deny-all`** + autorisations
explicites des seuls flux F1/F2/F3.

**3. Pourquoi.**
Parce que le risque structurel le plus grave ici est le **mouvement latéral** : la
plupart des autres faiblesses (SQLi, secret faible, token SA) ne deviennent un
**incident majeur** que parce qu'un pod compromis peut atteindre toute
l'infrastructure. Couper ces flux **casse la chaîne d'attaque** et **réduit le
rayon d'explosion** immédiatement, à faible coût. (La correction du code et le
durcissement des pods suivent, en défense en profondeur.)

---

## Bilan Phase 1

| Élément | État |
|---------|------|
| App micro-services fonctionnelle | ✅ déployée sur k3s, accessible |
| Conteneurisation | ✅ 2 images buildées + importées dans containerd |
| Déploiement K8s minimal | ✅ Deployments + Services, SA default, no NetworkPolicy |
| Surface d'attaque comprise | ✅ 6 faiblesses identifiées et (partiellement) démontrées |
| Failles volontaires | ✅ V1–V6, à corriger en Phase 3 |
