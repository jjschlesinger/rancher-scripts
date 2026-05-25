#!/usr/bin/env bash
# Configure Fleet GitOps for multi-cluster application delivery.
#
# Fleet is bundled with Rancher 2.6+ and already running after 01-install-rancher-server.sh.
# This script does the post-install configuration for B2B SaaS use:
#
#   1. Creates Fleet workspaces (one per customer or tier)
#   2. Creates a GitRepo resource pointing to your app repo
#   3. Creates cluster groups for routing deployments (prod / staging / dev)
#   4. Outputs a dashboard URL
#
# Fleet model for B2B SaaS:
#   - Your Rancher server = Fleet manager (hub)
#   - Each customer cluster = Fleet downstream cluster
#   - GitRepo resources declare WHAT to deploy and WHERE
#   - Cluster selectors (labels) determine which clusters get which bundles
#
# Usage:
#   source /root/.rancher-credentials
#   FLEET_REPO_URL=https://github.com/your-org/fleet-config.git bash 06-install-fleet-gitops.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

[[ -f /root/.rancher-credentials ]] && source /root/.rancher-credentials

# ── Configuration ──────────────────────────────────────────────────────────────

RANCHER_URL="${RANCHER_URL:-}"
RANCHER_TOKEN="${RANCHER_TOKEN:-}"

# Your fleet GitOps repository
FLEET_REPO_URL="${FLEET_REPO_URL:-}"
FLEET_REPO_BRANCH="${FLEET_REPO_BRANCH:-main}"

# Private repo: set to a Kubernetes secret name with git credentials
FLEET_REPO_SECRET="${FLEET_REPO_SECRET:-}"

# Namespaces / workspaces to create
FLEET_WORKSPACES=("fleet-default" "fleet-prod" "fleet-staging" "fleet-dev")

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# ── Validate ───────────────────────────────────────────────────────────────────

validate() {
  [[ -n "$RANCHER_URL"   ]] || log_error "RANCHER_URL not set"
  [[ -n "$RANCHER_TOKEN" ]] || log_error "RANCHER_TOKEN not set"
  require_command kubectl
  require_command curl
  require_command jq
}

# ── Verify Fleet is running ────────────────────────────────────────────────────

check_fleet() {
  log_section "Fleet Status"
  export KUBECONFIG

  # Fleet ships with Rancher — these should already exist
  local fleet_pods
  fleet_pods=$(kubectl get pods -n cattle-fleet-system --no-headers 2>/dev/null | wc -l)

  if [[ "$fleet_pods" -eq 0 ]]; then
    log_warn "Fleet pods not found. Installing standalone Fleet..."
    install_fleet_standalone
  else
    log_ok "Fleet running: $fleet_pods pods in cattle-fleet-system"
  fi
}

install_fleet_standalone() {
  # Only needed if running Fleet outside Rancher
  helm repo add fleet https://rancher.github.io/fleet-helm-charts --force-update
  helm repo update

  helm upgrade --install fleet-crd fleet/fleet-crd \
    --namespace cattle-fleet-system \
    --create-namespace \
    --wait

  helm upgrade --install fleet fleet/fleet \
    --namespace cattle-fleet-system \
    --create-namespace \
    --wait --timeout 5m

  log_ok "Fleet installed standalone"
}

# ── Create Fleet workspaces ────────────────────────────────────────────────────

create_workspaces() {
  log_section "Fleet Workspaces"
  export KUBECONFIG

  for workspace in "${FLEET_WORKSPACES[@]}"; do
    if kubectl get clusterregistrationnamespace "$workspace" &>/dev/null 2>&1 || \
       kubectl get namespace "$workspace" &>/dev/null 2>&1; then
      log_ok "Workspace $workspace already exists"
      continue
    fi

    # fleet-default is built-in; others are Fleet cluster namespaces
    if [[ "$workspace" != "fleet-default" ]]; then
      kubectl create namespace "$workspace" --dry-run=client -o yaml | kubectl apply -f -
      kubectl label namespace "$workspace" \
        "fleet.cattle.io/cluster-namespace=true" \
        --overwrite
    fi
    log_ok "Workspace: $workspace"
  done
}

# ── Create cluster groups ──────────────────────────────────────────────────────

create_cluster_groups() {
  log_section "Cluster Groups"
  export KUBECONFIG

  # Production group — clusters labelled environment=prod
  kubectl apply -f - <<'EOF'
apiVersion: fleet.cattle.io/v1alpha1
kind: ClusterGroup
metadata:
  name: production
  namespace: fleet-default
spec:
  selector:
    matchLabels:
      environment: prod
EOF

  # Staging group
  kubectl apply -f - <<'EOF'
apiVersion: fleet.cattle.io/v1alpha1
kind: ClusterGroup
metadata:
  name: staging
  namespace: fleet-default
spec:
  selector:
    matchLabels:
      environment: staging
EOF

  # Dev group
  kubectl apply -f - <<'EOF'
apiVersion: fleet.cattle.io/v1alpha1
kind: ClusterGroup
metadata:
  name: dev
  namespace: fleet-default
spec:
  selector:
    matchLabels:
      environment: dev
EOF

  log_ok "Cluster groups created: production, staging, dev"
}

# ── Register GitRepo ───────────────────────────────────────────────────────────

create_gitrepo() {
  [[ -z "$FLEET_REPO_URL" ]] && {
    log_warn "FLEET_REPO_URL not set — skipping GitRepo creation."
    log_info "You can create it later from the Rancher UI: Continuous Delivery → Git Repos"
    return
  }

  log_section "Fleet GitRepo: $FLEET_REPO_URL"
  export KUBECONFIG

  local secret_ref=""
  [[ -n "$FLEET_REPO_SECRET" ]] && \
    secret_ref="clientSecretName: ${FLEET_REPO_SECRET}"

  kubectl apply -f - <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: app-config
  namespace: fleet-default
spec:
  repo: ${FLEET_REPO_URL}
  branch: ${FLEET_REPO_BRANCH}
  ${secret_ref}
  targets:
  # Deploy to all downstream clusters by default.
  # Narrow this with clusterSelector or clusterGroup.
  - clusterSelector: {}
EOF

  log_ok "GitRepo registered: $FLEET_REPO_URL ($FLEET_REPO_BRANCH)"
}

# ── Print repo structure guide ─────────────────────────────────────────────────

print_repo_guide() {
  log_section "Recommended Fleet Repo Structure"
  cat <<'GUIDE'
Your Fleet config repo should look like:

  fleet-config/
  ├── fleet.yaml               # root bundle config
  ├── namespaces/              # shared namespace definitions
  │   └── fleet.yaml
  │
  ├── apps/
  │   ├── fleet.yaml           # targets: all clusters
  │   └── my-saas-app/
  │       ├── fleet.yaml
  │       └── manifests/
  │           ├── deployment.yaml
  │           ├── service.yaml
  │           └── configmap.yaml
  │
  └── customer-configs/        # per-customer overrides
      ├── acme/
      │   ├── fleet.yaml       # targets: customer=acme
      │   └── values.yaml
      └── globex/
          ├── fleet.yaml       # targets: customer=globex
          └── values.yaml

fleet.yaml example for customer targeting:
  ---
  namespace: my-app
  helm:
    releaseName: my-app
    valuesFiles:
      - values.yaml
  targets:
  - name: acme-prod
    clusterSelector:
      matchLabels:
        customer: acme
        environment: prod

GUIDE
}

# ── Print Fleet dashboard link ─────────────────────────────────────────────────

print_summary() {
  log_section "Fleet GitOps Ready"
  echo -e "${GREEN}Fleet UI: ${BOLD}${RANCHER_URL}/dashboard/c/local/fleet${NC}"
  echo ""
  echo -e "${CYAN}Cluster labelling convention for B2B SaaS:${NC}"
  echo -e "  customer=<slug>       # e.g. customer=acme"
  echo -e "  environment=prod|staging|dev"
  echo -e "  cloud=aks|eks|k3s|k8s"
  echo ""
  echo -e "${YELLOW}Label clusters in Rancher UI or via kubectl:${NC}"
  echo -e "  kubectl label cluster <name> customer=acme environment=prod cloud=aks -n fleet-default"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "Fleet GitOps Setup"
  validate
  check_fleet
  create_workspaces
  create_cluster_groups
  create_gitrepo
  print_repo_guide
  print_summary
}

main "$@"
