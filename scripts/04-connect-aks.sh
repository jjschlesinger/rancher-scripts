#!/usr/bin/env bash
# Get AKS credentials and import the cluster into Rancher.
#
# This script:
#   1. Logs in to Azure (or uses existing session)
#   2. Pulls kubeconfig for the target AKS cluster
#   3. Merges it into a temp kubeconfig
#   4. Calls 03-import-cluster.sh to register with Rancher
#
# Requirements:
#   - Azure CLI installed (00-install-prerequisites.sh)
#   - Rancher running and credentials in /root/.rancher-credentials
#   - Service principal or user with "Azure Kubernetes Service Cluster User Role"
#     on the AKS cluster
#
# Usage:
#   # Interactive login:
#   sudo bash 04-connect-aks.sh
#
#   # Non-interactive (CI/CD), using service principal:
#   sudo AZ_SUBSCRIPTION_ID=xxx AZ_RESOURCE_GROUP=my-rg AZ_CLUSTER_NAME=my-aks \
#        AZ_SP_ID=xxx AZ_SP_SECRET=xxx AZ_TENANT_ID=xxx \
#        bash 04-connect-aks.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_command az
require_command kubectl
require_command curl
require_command jq

# ── Configuration ──────────────────────────────────────────────────────────────

# Source Rancher credentials if the file exists
[[ -f /root/.rancher-credentials ]] && source /root/.rancher-credentials

RANCHER_URL="${RANCHER_URL:-}"
RANCHER_TOKEN="${RANCHER_TOKEN:-}"

# Azure target
AZ_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID:-}"
AZ_RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-}"
AZ_CLUSTER_NAME="${AZ_CLUSTER_NAME:-}"
AZ_TENANT_ID="${AZ_TENANT_ID:-}"

# Service principal (optional — leave empty for interactive login)
AZ_SP_ID="${AZ_SP_ID:-}"
AZ_SP_SECRET="${AZ_SP_SECRET:-}"

# Rancher label metadata
CUSTOMER_LABEL="${CUSTOMER_LABEL:-}"
ENVIRONMENT_LABEL="${ENVIRONMENT_LABEL:-prod}"

TEMP_KUBECONFIG=$(mktemp /tmp/aks-kubeconfig-XXXXXX.yaml)
trap 'rm -f "$TEMP_KUBECONFIG"' EXIT

# ── Validate ───────────────────────────────────────────────────────────────────

validate() {
  [[ -n "$RANCHER_URL"    ]] || log_error "RANCHER_URL not set. Source /root/.rancher-credentials or set manually."
  [[ -n "$RANCHER_TOKEN"  ]] || log_error "RANCHER_TOKEN not set."

  if [[ -z "$AZ_RESOURCE_GROUP" || -z "$AZ_CLUSTER_NAME" ]]; then
    log_section "AKS Cluster Selection"
    prompt_with_default "Azure Subscription ID" "" AZ_SUBSCRIPTION_ID
    prompt_with_default "Resource Group"         "" AZ_RESOURCE_GROUP
    prompt_with_default "AKS Cluster Name"       "" AZ_CLUSTER_NAME
    [[ -n "$AZ_SUBSCRIPTION_ID" && -n "$AZ_RESOURCE_GROUP" && -n "$AZ_CLUSTER_NAME" ]] || \
      log_error "Subscription ID, Resource Group, and Cluster Name are all required."
  fi
}

# ── Azure login ────────────────────────────────────────────────────────────────

az_login() {
  log_section "Azure Authentication"

  if [[ -n "$AZ_SP_ID" && -n "$AZ_SP_SECRET" && -n "$AZ_TENANT_ID" ]]; then
    log_info "Logging in with service principal..."
    az login --service-principal \
      --username "$AZ_SP_ID" \
      --password "$AZ_SP_SECRET" \
      --tenant "$AZ_TENANT_ID" \
      --output none
    log_ok "Service principal login successful"
  else
    log_info "Checking existing Azure session..."
    if ! az account show &>/dev/null; then
      log_info "No active session — starting device login..."
      az login --output none
    fi
    log_ok "Azure session active"
  fi

  if [[ -n "$AZ_SUBSCRIPTION_ID" ]]; then
    az account set --subscription "$AZ_SUBSCRIPTION_ID"
    log_ok "Active subscription: $AZ_SUBSCRIPTION_ID"
  else
    local sub
    sub=$(az account show --query id -o tsv)
    AZ_SUBSCRIPTION_ID="$sub"
    log_ok "Using subscription: $AZ_SUBSCRIPTION_ID"
  fi
}

# ── Fetch AKS kubeconfig ───────────────────────────────────────────────────────

get_aks_credentials() {
  log_section "AKS Credentials"
  log_info "Cluster: $AZ_CLUSTER_NAME in $AZ_RESOURCE_GROUP"

  # Verify cluster exists
  az aks show \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --name "$AZ_CLUSTER_NAME" \
    --query "provisioningState" -o tsv | grep -q "Succeeded" \
    || log_error "AKS cluster $AZ_CLUSTER_NAME not found or not in Succeeded state"

  az aks get-credentials \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --name "$AZ_CLUSTER_NAME" \
    --file "$TEMP_KUBECONFIG" \
    --overwrite-existing

  log_ok "kubeconfig written to $TEMP_KUBECONFIG"
}

# ── Verify cluster access ──────────────────────────────────────────────────────

verify_cluster() {
  log_section "Verifying Cluster Access"

  local node_count
  node_count=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | wc -l)
  log_ok "Connected to AKS — $node_count nodes"

  local k8s_version
  k8s_version=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl version --short 2>/dev/null | grep "Server" || \
                KUBECONFIG="$TEMP_KUBECONFIG" kubectl version 2>/dev/null | grep "Server")
  log_info "Kubernetes: $k8s_version"
}

# ── Import into Rancher ────────────────────────────────────────────────────────

import_to_rancher() {
  log_section "Importing into Rancher"

  local display_name="${AZ_CLUSTER_NAME}"
  [[ -n "$CUSTOMER_LABEL" ]] && display_name="${CUSTOMER_LABEL}-${AZ_CLUSTER_NAME}"

  RANCHER_URL="$RANCHER_URL" \
  RANCHER_TOKEN="$RANCHER_TOKEN" \
  CLUSTER_DISPLAY_NAME="$display_name" \
  CUSTOMER_LABEL="$CUSTOMER_LABEL" \
  ENVIRONMENT_LABEL="$ENVIRONMENT_LABEL" \
  CLOUD_LABEL="aks" \
  KUBECONFIG="$TEMP_KUBECONFIG" \
    bash "$SCRIPT_DIR/03-import-cluster.sh"
}

# ── Store kubeconfig for ongoing use ──────────────────────────────────────────

persist_kubeconfig() {
  local target_dir="/root/.kube/clusters"
  mkdir -p "$target_dir"
  local target="${target_dir}/${AZ_CLUSTER_NAME}.yaml"
  cp "$TEMP_KUBECONFIG" "$target"
  chmod 600 "$target"
  log_ok "kubeconfig saved to $target"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "AKS → Rancher Connection"
  validate
  az_login
  get_aks_credentials
  verify_cluster
  import_to_rancher
  persist_kubeconfig

  log_section "AKS Cluster Connected"
  log_ok "Cluster $AZ_CLUSTER_NAME is now managed by Rancher"
  log_info "To connect additional AKS clusters, re-run with different AZ_CLUSTER_NAME"
}

main "$@"
