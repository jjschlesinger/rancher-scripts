# Rancher Multi-Cluster Management

Central Rancher deployment for managing customer Kubernetes clusters (AKS, EKS, K3s, vanilla K8s) without cloud lock-in.

## Architecture

```
                          ┌─────────────────────────────────┐
                          │      Rancher Management Server   │
                          │  (Ubuntu VM — your infrastructure)│
                          │                                   │
                          │  k3s  ──  Rancher  ──  Fleet     │
                          │           │         │             │
                          │         HTTPS     GitOps         │
                          └─────────────────────────────────┘
                                      │ outbound only ▼
              ┌───────────────────────┼──────────────────────┐
              │                       │                      │
   ┌──────────▼──────┐   ┌────────────▼───┐   ┌─────────────▼──┐
   │  Customer A      │   │  Customer B    │   │  Dev Cluster    │
   │  AKS (Azure)     │   │  EKS (AWS)     │   │  k3s (2 nodes)  │
   │  Rancher agent   │   │  Rancher agent │   │  Rancher agent  │
   └─────────────────┘   └────────────────┘   └─────────────────┘
```

**Key properties:**
- Rancher agents on customer clusters make **outbound** connections only — no inbound firewall rules required on customer infrastructure
- Fleet GitOps handles application delivery across all clusters using label selectors
- Monitoring per-cluster via `kube-prometheus-stack`

---

## Scripts

| Script | Purpose | Run on |
|--------|---------|--------|
| `00-install-prerequisites.sh` | Docker, kubectl, Helm, k9s, az, aws, Rancher CLI | Rancher server |
| `01-install-rancher-server.sh` | k3s + cert-manager + Rancher | Rancher server |
| `02a-create-dev-k3s-server.sh` | k3s control-plane node | Dev machine 1 |
| `02b-create-dev-k3s-agent.sh` | k3s worker node | Dev machine 2 |
| `03-import-cluster.sh` | Import any cluster into Rancher | Rancher server |
| `04-connect-aks.sh` | AKS → Rancher import | Rancher server |
| `05-connect-eks.sh` | EKS → Rancher import | Rancher server |
| `06-install-fleet-gitops.sh` | Fleet workspaces + cluster groups | Rancher server |
| `07-install-monitoring.sh` | Prometheus + Grafana + alerts | Any cluster |

---

## Quickstart

### 1. Rancher Server

```bash
# On a fresh Ubuntu 22.04/24.04 VM (≥2 vCPU, ≥4 GB RAM)
git clone https://github.com/your-org/rancher-config.git
cd rancher-config

sudo bash scripts/00-install-prerequisites.sh

sudo RANCHER_HOSTNAME=rancher.mycompany.com \
     RANCHER_TLS=letsEncrypt \
     LETSENCRYPT_EMAIL=ops@mycompany.com \
     bash scripts/01-install-rancher-server.sh

# Credentials are saved to /root/.rancher-credentials
```

### 2. Dev k3s Cluster (2 nodes)

```bash
# On dev machine 1 (control plane):
sudo bash scripts/02a-create-dev-k3s-server.sh
# Note the K3S_URL and K3S_TOKEN printed at the end

# On dev machine 2 (worker):
sudo K3S_URL=https://<server-ip>:6443 \
     K3S_TOKEN=<token> \
     bash scripts/02b-create-dev-k3s-agent.sh

# Import the dev cluster into Rancher (run on Rancher server):
source /root/.rancher-credentials
CLUSTER_DISPLAY_NAME=dev \
ENVIRONMENT_LABEL=dev \
CLOUD_LABEL=k3s \
KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
bash scripts/03-import-cluster.sh
```

### 3. Connect a Customer AKS Cluster

```bash
source /root/.rancher-credentials

AZ_RESOURCE_GROUP=customer-acme-rg \
AZ_CLUSTER_NAME=acme-prod \
CUSTOMER_LABEL=acme \
ENVIRONMENT_LABEL=prod \
bash scripts/04-connect-aks.sh
```

### 4. Connect a Customer EKS Cluster

```bash
source /root/.rancher-credentials

EKS_CLUSTER_NAME=globex-prod \
EKS_REGION=us-east-1 \
CUSTOMER_LABEL=globex \
ENVIRONMENT_LABEL=prod \
bash scripts/05-connect-eks.sh
```

### 5. Connect a Vanilla K8s / K3s Cluster

```bash
source /root/.rancher-credentials

CLUSTER_DISPLAY_NAME=customer-xyz-k3s \
CUSTOMER_LABEL=xyz \
ENVIRONMENT_LABEL=prod \
CLOUD_LABEL=k3s \
KUBECONFIG=/path/to/customer-kubeconfig \
bash scripts/03-import-cluster.sh
```

### 6. GitOps with Fleet

```bash
source /root/.rancher-credentials

FLEET_REPO_URL=https://github.com/your-org/fleet-config \
FLEET_REPO_BRANCH=main \
bash scripts/06-install-fleet-gitops.sh
```

### 7. Monitoring

```bash
# On the Rancher management cluster:
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
     GRAFANA_PASSWORD=MySecret \
     ALERTMANAGER_SLACK_WEBHOOK=https://hooks.slack.com/... \
     ALERTMANAGER_SLACK_CHANNEL=#k8s-alerts \
     bash scripts/07-install-monitoring.sh

# For each customer cluster, use Rancher UI:
#   Cluster → Apps → Charts → Monitoring
```

---

## Cluster Labelling Convention

All imported clusters should be labelled consistently. This drives Fleet GitOps targeting and monitoring grouping.

```bash
# Using kubectl on the Rancher management cluster
kubectl label clusters.fleet.cattle.io <cluster-name> \
  customer=acme \
  environment=prod \
  cloud=aks \
  -n fleet-default

# Or via Rancher CLI
rancher clusters edit <cluster-name>
```

| Label | Values |
|-------|--------|
| `customer` | Customer slug, e.g. `acme`, `globex` |
| `environment` | `prod`, `staging`, `dev` |
| `cloud` | `aks`, `eks`, `gke`, `k3s`, `k8s` |

---

## Configuration Reference

All scripts read configuration from environment variables. Key variables:

### Rancher Server (`01-install-rancher-server.sh`)

| Variable | Default | Description |
|----------|---------|-------------|
| `RANCHER_HOSTNAME` | `<ip>.nip.io` | FQDN for Rancher UI |
| `RANCHER_TLS` | `rancher` | `rancher` (self-signed) or `letsEncrypt` |
| `RANCHER_VERSION` | `latest` | Pin to e.g. `2.10.1` |
| `RANCHER_PASSWORD` | auto-generated | Initial admin password |
| `LETSENCRYPT_EMAIL` | — | Required when `RANCHER_TLS=letsEncrypt` |

### Credentials File (`/root/.rancher-credentials`)

Created automatically by `01-install-rancher-server.sh`. Source it before running other scripts:

```bash
source /root/.rancher-credentials
# Exports: RANCHER_URL, RANCHER_TOKEN, RANCHER_PASSWORD
```

---

## Production Hardening Checklist

- [ ] Run Rancher in 3-node HA mode (use RKE2 instead of single-node k3s)
- [ ] Store `/root/.rancher-credentials` in a secrets manager (Vault, AWS Secrets Manager)
- [ ] Restrict Rancher API token scopes per team
- [ ] Enable Rancher RBAC — create project-scoped roles per customer
- [ ] Configure Rancher backup operator (etcd snapshots to S3)
- [ ] Enable NeuVector for runtime container security
- [ ] Set up PodDisruptionBudgets for customer-facing workloads
- [ ] Configure log aggregation (Rancher Logging → Elasticsearch/Loki)
- [ ] Review `kubectl get clusterrolebindings` on each imported cluster

---

## Useful Commands

```bash
# Switch between cluster contexts
kubectx

# View all clusters registered in Rancher
source /root/.rancher-credentials
curl -fsSk -H "Authorization: Bearer $RANCHER_TOKEN" \
  "$RANCHER_URL/v3/clusters" | jq '[.data[] | {name:.name, state:.state, cloud:.labels.cloud}]'

# Watch Fleet bundle deployments
kubectl get bundles -A
kubectl get bundledeployments -A

# Force Fleet to re-sync a repo
kubectl annotate gitrepo app-config \
  fleet.cattle.io/force-sync=$(date +%s) \
  -n fleet-default
```
