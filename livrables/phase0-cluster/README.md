# Phase 0 — Mise en place et vérification du cluster k3s

> Projet DevSecOps — cluster k3s mono-VM avec worker simulé.
> Environnement réel : **Kali GNU/Linux Rolling 2025.2**, kernel `6.12.25-amd64`, 4 vCPU / 4 Go RAM.

---

## 1. Architecture cible et obtenue

```
                ┌──────────────────────────────────────────────┐
                │                MÊME MACHINE (Kali)            │
                │                                               │
                │   ┌─────────────────┐   ┌─────────────────┐  │
                │   │   k3s-server     │   │    k3s-agent    │  │
                │   │  (control-plane) │   │   (worker1)     │  │
                │   │                  │   │                 │  │
                │   │  API     :6443   │◄──┤  kubelet :10250 │  │
                │   │  Supervisor:6444 │   │  LB      :6445   │  │
                │   │  disable-agent   │   │  exécute les    │  │
                │   │  (pas de kubelet)│   │  pods           │  │
                │   └─────────────────┘   └─────────────────┘  │
                └──────────────────────────────────────────────┘
                       Communication interne via IP 192.168.30.150
```

| Élément | Valeur |
|---------|--------|
| Node control-plane | `kali` → bascule en `worker1` (voir explication) |
| Node worker | `worker1` — `Ready`, `v1.34.6+k3s1` |
| IP interne (API + jonction worker) | `192.168.30.150` |
| Runtime conteneur | `containerd://2.2.2-bd1.34` |

### Pourquoi cette configuration particulière ?

Sur **une seule machine**, un k3s-server fait par défaut **aussi** office de worker
(il lance son propre kubelet sur le port `10250`). Pour ajouter un second node
(`k3s-agent`) sur le **même hôte** sans **collision de port** sur `10250`/`10256`,
on bascule le server en **control-plane pur** via l'option `disable-agent: true`.
Le server n'exécute alors plus de pods ; c'est `worker1` qui porte tous les workloads.

> ⚠️ Piège rencontré : `server` et `agent` lisent par défaut le **même** fichier
> `/etc/rancher/k3s/config.yaml`. Or `disable-agent` est une option **réservée au server**.
> L'agent plantait donc avec `flag provided but not defined: -disable-agent`.
> **Correctif** : fichier de config dédié à l'agent
> (`/etc/rancher/k3s/config-agent.yaml`) passé via `--config`, pour qu'il ne lise
> plus le `config.yaml` du server. Voir `fix-worker.sh`.

---

## 2. Scripts de mise en place

| Script | Rôle |
|--------|------|
| `setup-worker.sh` | Bascule server en `disable-agent` + installe l'agent `worker1` (LB 6445) |
| `fix-worker.sh` | Correctif : isole la config de l'agent (`config-agent.yaml`) |

Réversibilité :
```bash
sudo /usr/local/bin/k3s-agent-uninstall.sh         # retire l'agent
# puis retirer 'disable-agent: true' de /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s                          # le node redevient control-plane+worker
```

---

## 3. Preuves de vérification

### 3.1 Nodes
```
$ kubectl get nodes -o wide
NAME      STATUS   ROLES    AGE   VERSION        INTERNAL-IP      CONTAINER-RUNTIME
worker1   Ready    <none>   16s   v1.34.6+k3s1   192.168.30.150   containerd://2.2.2-bd1.34
```

### 3.2 Services systemd
```
k3s       : active     (server / control-plane)
k3s-agent : active     (worker1)
```

### 3.3 Ports — séparation logique server / agent
```
$ ss -lntp | egrep ':6443|:6444|:6445|:10250'
127.0.0.1:6445   k3s-agent     # LB worker
127.0.0.1:6444   k3s-server    # Supervisor
*:10250          k3s-agent     # Kubelet
*:6443           k3s-server    # API Kubernetes
```

| Port | Processus | Rôle |
|------|-----------|------|
| 6443 | k3s-server | API Server Kubernetes |
| 6444 | k3s-server | Supervisor / remotedialer |
| 6445 | k3s-agent | Load-balancer worker |
| 10250 | k3s-agent | Kubelet |

➡️ **Aucune collision de port**, séparation logique server / agent respectée.

### 3.4 Pods système replanifiés sur worker1
```
NAMESPACE     NAME                         READY   STATUS    NODE
kube-system   coredns-...                  1/1     Running   worker1
kube-system   local-path-provisioner-...   1/1     Running   worker1
kube-system   metrics-server-...           1/1     Running   worker1
kube-system   traefik-...                  1/1     Running   worker1
kube-system   svclb-traefik-...            2/2     Running   worker1
```

---

## 4. Réponses aux questions d'observation (PDF Questions — Phases 0 et 1)

### A) Observation de l'architecture Kubernetes simulée

**1. Processus distincts control-plane / worker**
- **Control-plane** : processus `k3s server` (PID du service `k3s`). Il héberge
  l'`kube-apiserver` (6443), le `supervisor`/remotedialer (6444), le scheduler,
  le controller-manager et le datastore (SQLite/kine par défaut sur k3s).
- **Worker** : processus `k3s agent` (service `k3s-agent`). Il héberge le
  **kubelet** (10250), le **kube-proxy** et le **load-balancer client** (6445)
  qui relaie vers l'API server.

**2. Ports qui identifient la séparation server / agent**
`6443` + `6444` appartiennent au processus `k3s-server` ; `6445` + `10250`
appartiennent au processus `k3s-agent`. La commande
`ss -lntp | egrep ':6443|:6444|:6445|:10250'` montre clairement les deux PID distincts.

**3. Où sont stockées les configurations sensibles**
| Élément | Emplacement | Protection |
|---------|-------------|-----------|
| kubeconfig admin | `/etc/rancher/k3s/k3s.yaml` | root only (0600) |
| kubeconfig utilisateur | `/home/kali/.kube/config` | `-rw-------` (0600), propriétaire `kali` |
| Token de jonction | `/var/lib/rancher/k3s/server/node-token` | root only |
| Variables agent (URL+token) | `/etc/systemd/system/k3s-agent.service.env` | lisible root |
| Secrets / datastore | `/var/lib/rancher/k3s/server/` (kine/SQLite) | root only |

**4. Commande qui prouve que le worker est joint**
```bash
kubectl get nodes -o wide      # worker1 doit apparaître en STATUS Ready
```

**5. Ce qui prouve que le cluster est fonctionnel mais volontairement peu sécurisé**
Fonctionnel : node `Ready`, pods système `Running`, API joignable.
Peu sécurisé : kubelet exposé sur `*:10250`, **aucune NetworkPolicy**, secrets
**non chiffrés** at-rest, **RBAC par défaut**, ServiceAccount `default` utilisé.

**À comprendre — séparation logique vs physique :**
Ce ne sont **pas deux machines distinctes** mais deux **processus/services** sur
le même hôte (même OS, même kernel, même matériel). Donc **pas d'attaque
matérielle ni hyperviseur** possible entre les deux « nodes ». C'est néanmoins
**suffisant** pour : comprendre les rôles Kubernetes, analyser la surface
d'attaque, et raisonner en défense en profondeur (RBAC, NetworkPolicy,
PodSecurity, runtime security).

---

### B) Observation de la surface d'attaque initiale

**1. Services exposés par défaut** : `kube-apiserver` (6443, sur `*` donc toutes
interfaces), `kubelet` (10250, sur `*`), supervisor (6444, localhost), LB agent
(6445, localhost). Traefik (ingress) écoute aussi en NodePort.

**2. Le kubelet est-il accessible ? Sur quel port ? Risque ?**
Oui, sur `*:10250` (toutes interfaces). Risque : l'API kubelet permet, si elle est
mal authentifiée, de **lister les pods, lire des logs et exécuter des commandes
dans les conteneurs** (`/exec`, `/run`) → exécution de code à distance et
extraction de secrets montés dans les pods.

**3. NetworkPolicies actives ?**
```
$ kubectl get networkpolicies -A
No resources found
```
**Aucune.** Conséquence directe : **tous les pods peuvent communiquer entre eux
et vers l'extérieur sans restriction** (réseau « flat »). Un pod compromis peut
scanner et joindre n'importe quel autre service du cluster.

**4. Les secrets sont-ils chiffrés ? Protégés par RBAC spécifique ?**
- **Chiffrement at-rest** : non. k3s ne chiffre pas les secrets par défaut
  (pas d'`EncryptionConfiguration`). Ils sont stockés en **base64** (≠ chiffrement)
  dans le datastore.
- **RBAC spécifique** : non, RBAC par défaut. Tout compte ayant le verbe `get`
  sur les secrets de son namespace peut les lire.

**5. ServiceAccount utilisé par défaut par les pods** : le ServiceAccount
`default` du namespace, dont le token est **monté automatiquement** dans le pod
(`/var/run/secrets/kubernetes.io/serviceaccount/`).

**À comprendre :** Kubernetes applique une logique « ouvert par défaut, à
durcir » — il privilégie le fonctionnement avant la sécurité. Ce contexte est
**réaliste** : beaucoup de clusters en production restent dans cet état initial
(pas de NetworkPolicy, RBAC large, secrets non chiffrés) faute de durcissement.

---

### C) Lecture critique d'une attaque latérale

**1. Différence de rôle control-plane / worker**
- **Control-plane** : « cerveau » du cluster — expose l'API, décide du placement
  (scheduler), maintient l'état désiré, détient le datastore (donc les secrets).
- **Worker** : « bras » — exécute réellement les conteneurs via le kubelet.

**2. Pourquoi un attaquant vise le cluster et pas que l'application**
Compromettre l'application ne donne accès qu'à un service ; compromettre le
cluster (API, kubelet, token SA) donne accès à **l'orchestrateur** : déployer des
pods, lire tous les secrets, rebondir vers les autres workloads → impact massif.

**3. Actions possibles après compromission d'un pod**
Lire le token du ServiceAccount monté, interroger l'API
(`kubectl auth can-i --list`), énumérer services/secrets, scanner le réseau
interne, tenter une escalade (pod privileged, hostPath), exfiltrer des données.

**4. Sans NetworkPolicy, que peut faire un pod compromis sur le réseau interne**
Tout : joindre la DB, les autres APIs, l'API server, faire du scan de ports,
exfiltrer vers Internet. Le réseau plat **n'oppose aucune segmentation**.

**5. Sans RBAC strict, ce que permet un token volé**
Si le token (ServiceAccount `default` ou compte trop permissif) a des droits
larges, il permet de **lire les secrets, créer/supprimer des pods, voire
atteindre des privilèges cluster-admin** → prise de contrôle complète.

> Les questions **D)** (lien application ↔ infrastructure) et **E)** (synthèse
> DevSecOps) seront traitées une fois l'application déployée (Phase 1), car elles
> portent sur les flux applicatifs concrets.

---

## 5. État de l'environnement après la Phase 0

- ✅ Control-plane opérationnel (`k3s` active, API 6443)
- ✅ Worker `worker1` joint et `Ready`
- ✅ Réseau fonctionnel (pods système Running)
- ⚠️ Faiblesses **volontaires** conservées : kubelet 10250 exposé, pas de
  NetworkPolicy, pas de PodSecurity, secrets non chiffrés, RBAC par défaut.
  → C'est le **contexte initial** du projet, à durcir en Phase 3.
