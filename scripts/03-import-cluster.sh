#!/usr/bin/env bash
# Import ANY Kubernetes cluster (AKS, EKS, K3s, vanilla K8s) into Rancher.
#
# How it works:
#   Rancher's "import" model deploys a lightweight agent on the target cluster.
#   The agent makes an OUTBOUND connection to Rancher — no inbound access to
#   customer infrastructure required. This is the recommended B2B SaaS pattern.
#
# Pre-requisites:
#   - Rancher server running and accessible
#   - kubectl configured to talk to the TARGET cluster (set KUBECONFIG)
#   - /root/.rancher-credentials on the Rancher server (from 01-install-rancher-server.sh)
#
# Usage:
#   # Source Rancher credentials first
#   source /root/.rancher-credentials
#
#   CLUSTER_DISPLAY_NAME="customer-acme-prod" \
#   RANCHER_URL=https://rancher.mycompany.com \
#   RANCHER_TOKEN=token-xxxxx:yyyyy \
#   KUBECONFIG=/path/to/customer-kubeconfig \
#   bash 03-import-cluster.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ── Configuration ──────────────────────────────────────────────────────────────

RANCHER_URL="${RANCHER_URL:-}"
RANCHER_TOKEN="${RANCHER_TOKEN:-}"
CLUSTER_DISPLAY_NAME="${CLUSTER_DISPLAY_NAME:-}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Optional labels for multi-tenant organisation
CUSTOMER_LABEL="${CUSTOMER_LABEL:-}"        # e.g. "acme"
ENVIRONMENT_LABEL="${ENVIRONMENT_LABEL:-}"  # e.g. "prod" | "staging" | "dev"
CLOUD_LABEL="${CLOUD_LABEL:-}"              # e.g. "aks" | "eks" | "k3s" | "k8s"

# ── Validate inputs ────────────────────────────────────────────────────────────

validate() {
  [[ -n "$RANCHER_URL"    ]] || log_error "RANCHER_URL is required"
  [[ -n "$RANCHER_TOKEN"  ]] || log_error "RANCHER_TOKEN is required"
  [[ -n "$CLUSTER_DISPLAY_NAME" ]] || log_error "CLUSTER_DISPLAY_NAME is required"
  [[ -f "$KUBECONFIG"     ]] || log_error "KUBECONFIG file not found: $KUBECONFIG"

  require_command kubectl
  require_command curl
  require_command jq

  log_info "Target cluster:  $CLUSTER_DISPLAY_NAME"
  log_info "Rancher URL:     $RANCHER_URL"
  log_info "KUBECONFIG:      $KUBECONFIG"
}

# ── Check target cluster connectivity ─────────────────────────────────────────

check_target_cluster() {
  log_section "Target Cluster Connectivity"
  local current_context
  current_context=$(KUBECONFIG="$KUBECONFIG" kubectl config current-context 2>/dev/null)
  log_info "kubectl context: $current_context"

  KUBECONFIG="$KUBECONFIG" kubectl cluster-info --request-timeout=10s | head -1
  local node_count
  node_count=$(KUBECONFIG="$KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | wc -l)
  log_ok "Cluster reachable — $node_count nodes"
}

# ── Create cluster record in Rancher ──────────────────────────────────────────

create_rancher_cluster() {
  log_section "Creating Cluster Record in Rancher"

  # Build labels object
  local labels='{}'
  [[ -n "$CUSTOMER_LABEL"    ]] && labels=$(echo "$labels" | jq --arg v "$CUSTOMER_LABEL"    '. + {"customer": $v}')
  [[ -n "$ENVIRONMENT_LABEL" ]] && labels=$(echo "$labels" | jq --arg v "$ENVIRONMENT_LABEL" '. + {"environment": $v}')
  [[ -n "$CLOUD_LABEL"       ]] && labels=$(echo "$labels" | jq --arg v "$CLOUD_LABEL"       '. + {"cloud": $v}')

  local payload
  payload=$(jq -n \
    --arg name "$CLUSTER_DISPLAY_NAME" \
    --argjson labels "$labels" \
    '{
      "type": "cluster",
      "name": $name,
      "labels": $labels,
      "genericEngineConfig": {"driverName": "imported"},
      "annotations": {
        "field.cattle.io/description": ("Imported cluster: " + $name)
      }
    }')

  local response
  response=$(curl -fsSk -X POST \
    -H "Authorization: Bearer $RANCHER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${RANCHER_URL}/v3/clusters")

  CLUSTER_ID=$(echo "$response" | jq -r '.id // empty')
  [[ -n "$CLUSTER_ID" ]] || log_error "Failed to create cluster in Rancher. Response: $response"

  log_ok "Cluster record created: $CLUSTER_ID"
}

# ── Get registration manifest ──────────────────────────────────────────────────

get_import_manifest() {
  log_section "Retrieving Import Manifest"

  # Registration tokens are created automatically; poll until available
  local manifest_url="" attempts=0 max_attempts=30
  while [[ -z "$manifest_url" || "$manifest_url" == "null" ]]; do
    manifest_url=$(curl -fsSk \
      -H "Authorization: Bearer $RANCHER_TOKEN" \
      "${RANCHER_URL}/v3/clusters/${CLUSTER_ID}/clusterregistrationtokens" \
      | jq -r '.data[0].manifestUrl // empty')

    attempts=$((attempts + 1))
    [[ $attempts -ge $max_attempts ]] && log_error "Timed out waiting for registration token"
    [[ -z "$manifest_url" || "$manifest_url" == "null" ]] && sleep 5
  done

  MANIFEST_URL="$manifest_url"
  log_ok "Manifest URL: $MANIFEST_URL"
}

# ── Apply manifest to target cluster ──────────────────────────────────────────

apply_manifest() {
  log_section "Applying Rancher Agent to Target Cluster"

  # Download and apply (insecure OK — internal network; for production, pin the cert)
  KUBECONFIG="$KUBECONFIG" kubectl apply -f "${MANIFEST_URL}" --insecure-skip-tls-verify 2>/dev/null || \
  KUBECONFIG="$KUBECONFIG" kubectl apply -f <(curl -fsSk "$MANIFEST_URL")

  log_ok "Rancher import agent applied to cluster"
}

# ── Wait for cluster to become active ─────────────────────────────────────────

wait_for_active() {
  log_section "Waiting for Cluster to Become Active"

  local state="" attempts=0 max_attempts=60
  while [[ "$state" != "active" ]]; do
    state=$(curl -fsSk \
      -H "Authorization: Bearer $RANCHER_TOKEN" \
      "${RANCHER_URL}/v3/clusters/${CLUSTER_ID}" \
      | jq -r '.state // "unknown"')

    log_info "Cluster state: $state (attempt $((attempts+1))/$max_attempts)"

    [[ "$state" == "active" ]] && break
    [[ "$state" == "error"  ]] && log_error "Cluster entered error state — check Rancher UI"
    attempts=$((attempts + 1))
    [[ $attempts -ge $max_attempts ]] && log_error "Timed out waiting for cluster to become active"
    sleep 10
  done

  log_ok "Cluster is active in Rancher"
}

# ── Print summary ──────────────────────────────────────────────────────────────

print_summary() {
  log_section "Import Complete"
  echo -e "${GREEN}Cluster:    ${BOLD}$CLUSTER_DISPLAY_NAME${NC}"
  echo -e "${GREEN}Cluster ID: ${BOLD}$CLUSTER_ID${NC}"
  echo -e "${GREEN}Rancher UI: ${BOLD}${RANCHER_URL}/dashboard/c/${CLUSTER_ID}/explorer${NC}"
  echo ""
  echo -e "${CYAN}The Rancher agent on the target cluster makes outbound connections only.${NC}"
  echo -e "${CYAN}No inbound firewall rules are needed on customer infrastructure.${NC}"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "Rancher Cluster Import"
  validate
  check_target_cluster
  create_rancher_cluster
  get_import_manifest
  apply_manifest
  wait_for_active
  print_summary
}

main "$@"
