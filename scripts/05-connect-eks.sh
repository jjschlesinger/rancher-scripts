#!/usr/bin/env bash
# Get EKS credentials and import the cluster into Rancher.
#
# This script:
#   1. Verifies AWS credentials (or prompts to configure)
#   2. Pulls kubeconfig for the target EKS cluster
#   3. Calls 03-import-cluster.sh to register with Rancher
#
# Requirements:
#   - AWS CLI v2 installed (00-install-prerequisites.sh)
#   - IAM permissions: eks:DescribeCluster, eks:ListClusters
#   - Rancher running and credentials in /root/.rancher-credentials
#
# Usage:
#   # With IAM role / instance profile (recommended on EC2):
#   sudo EKS_CLUSTER_NAME=my-cluster EKS_REGION=us-east-1 bash 05-connect-eks.sh
#
#   # With explicit credentials:
#   sudo AWS_ACCESS_KEY_ID=xxx AWS_SECRET_ACCESS_KEY=xxx \
#        EKS_CLUSTER_NAME=my-cluster EKS_REGION=us-east-1 \
#        bash 05-connect-eks.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_command aws
require_command kubectl
require_command curl
require_command jq

# ── Configuration ──────────────────────────────────────────────────────────────

[[ -f /root/.rancher-credentials ]] && source /root/.rancher-credentials

RANCHER_URL="${RANCHER_URL:-}"
RANCHER_TOKEN="${RANCHER_TOKEN:-}"

EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
EKS_REGION="${EKS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-}"

CUSTOMER_LABEL="${CUSTOMER_LABEL:-}"
ENVIRONMENT_LABEL="${ENVIRONMENT_LABEL:-prod}"

TEMP_KUBECONFIG=$(mktemp /tmp/eks-kubeconfig-XXXXXX.yaml)
trap 'rm -f "$TEMP_KUBECONFIG"' EXIT

# ── Validate ───────────────────────────────────────────────────────────────────

validate() {
  [[ -n "$RANCHER_URL"   ]] || log_error "RANCHER_URL not set. Source /root/.rancher-credentials or set manually."
  [[ -n "$RANCHER_TOKEN" ]] || log_error "RANCHER_TOKEN not set."

  if [[ -z "$EKS_CLUSTER_NAME" ]]; then
    prompt_with_default "EKS Cluster Name" "" EKS_CLUSTER_NAME
    prompt_with_default "AWS Region"       "$EKS_REGION" EKS_REGION
    [[ -n "$EKS_CLUSTER_NAME" ]] || log_error "EKS_CLUSTER_NAME is required."
  fi
}

# ── AWS credentials check ──────────────────────────────────────────────────────

check_aws_credentials() {
  log_section "AWS Credentials"

  local aws_cmd="aws"
  [[ -n "$AWS_PROFILE" ]] && aws_cmd="aws --profile $AWS_PROFILE"

  if ! $aws_cmd sts get-caller-identity &>/dev/null; then
    log_warn "No valid AWS credentials. Run 'aws configure' or set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY."
    aws configure
  fi

  local identity
  identity=$($aws_cmd sts get-caller-identity --query 'Arn' -o text)
  log_ok "AWS identity: $identity"
}

# ── Fetch EKS kubeconfig ───────────────────────────────────────────────────────

get_eks_credentials() {
  log_section "EKS Credentials"
  log_info "Cluster: $EKS_CLUSTER_NAME in $EKS_REGION"

  local aws_opts="--region $EKS_REGION"
  [[ -n "$AWS_PROFILE" ]] && aws_opts+=" --profile $AWS_PROFILE"

  # Verify cluster exists and is ACTIVE
  local cluster_status
  # shellcheck disable=SC2086
  cluster_status=$(aws $aws_opts eks describe-cluster \
    --name "$EKS_CLUSTER_NAME" \
    --query 'cluster.status' -o text 2>/dev/null || echo "NOT_FOUND")

  [[ "$cluster_status" == "ACTIVE" ]] || \
    log_error "EKS cluster $EKS_CLUSTER_NAME not found or not ACTIVE (status: $cluster_status)"

  # Write kubeconfig
  # shellcheck disable=SC2086
  aws $aws_opts eks update-kubeconfig \
    --name "$EKS_CLUSTER_NAME" \
    --kubeconfig "$TEMP_KUBECONFIG"

  log_ok "kubeconfig written to $TEMP_KUBECONFIG"
}

# ── Verify cluster access ──────────────────────────────────────────────────────

verify_cluster() {
  log_section "Verifying Cluster Access"

  local node_count
  node_count=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | wc -l)
  log_ok "Connected to EKS — $node_count nodes"

  local k8s_version
  k8s_version=$(KUBECONFIG="$TEMP_KUBECONFIG" kubectl version 2>/dev/null | grep "Server" | head -1)
  log_info "Kubernetes: $k8s_version"
}

# ── Import into Rancher ────────────────────────────────────────────────────────

import_to_rancher() {
  log_section "Importing into Rancher"

  local display_name="${EKS_CLUSTER_NAME}"
  [[ -n "$CUSTOMER_LABEL" ]] && display_name="${CUSTOMER_LABEL}-${EKS_CLUSTER_NAME}"

  RANCHER_URL="$RANCHER_URL" \
  RANCHER_TOKEN="$RANCHER_TOKEN" \
  CLUSTER_DISPLAY_NAME="$display_name" \
  CUSTOMER_LABEL="$CUSTOMER_LABEL" \
  ENVIRONMENT_LABEL="$ENVIRONMENT_LABEL" \
  CLOUD_LABEL="eks" \
  KUBECONFIG="$TEMP_KUBECONFIG" \
    bash "$SCRIPT_DIR/03-import-cluster.sh"
}

# ── Persist kubeconfig ─────────────────────────────────────────────────────────

persist_kubeconfig() {
  local target_dir="/root/.kube/clusters"
  mkdir -p "$target_dir"
  local target="${target_dir}/${EKS_CLUSTER_NAME}.yaml"
  cp "$TEMP_KUBECONFIG" "$target"
  chmod 600 "$target"
  log_ok "kubeconfig saved to $target"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "EKS → Rancher Connection"
  validate
  check_aws_credentials
  get_eks_credentials
  verify_cluster
  import_to_rancher
  persist_kubeconfig

  log_section "EKS Cluster Connected"
  log_ok "Cluster $EKS_CLUSTER_NAME is now managed by Rancher"
}

main "$@"
