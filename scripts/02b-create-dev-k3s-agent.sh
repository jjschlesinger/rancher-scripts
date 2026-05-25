#!/usr/bin/env bash
# Join the dev k3s cluster as a worker (agent) node.
# Run this on the SECOND dev cluster machine.
#
# Requirements:
#   - K3S_URL  — URL of the k3s server, e.g. https://10.0.1.10:6443
#   - K3S_TOKEN — node token from the server (in /var/lib/rancher/k3s/server/node-token)
#
# Usage:
#   sudo K3S_URL=https://10.0.1.10:6443 K3S_TOKEN=<token> bash 02b-create-dev-k3s-agent.sh
#
# Or copy /root/.k3s-dev-server from the server node and source it:
#   sudo bash -c 'source /root/.k3s-dev-server && bash 02b-create-dev-k3s-agent.sh'

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

# ── Configuration ──────────────────────────────────────────────────────────────

K3S_URL="${K3S_URL:-}"
K3S_TOKEN="${K3S_TOKEN:-}"
DEV_CLUSTER_NAME="${DEV_CLUSTER_NAME:-dev}"
K3S_VERSION="${K3S_VERSION:-}"
AGENT_NAME="${AGENT_NAME:-${DEV_CLUSTER_NAME}-worker-1}"

# ── Validate inputs ────────────────────────────────────────────────────────────

validate_inputs() {
  if [[ -z "$K3S_URL" ]]; then
    log_error "K3S_URL is required. Example: export K3S_URL=https://10.0.1.10:6443"
  fi
  if [[ -z "$K3S_TOKEN" ]]; then
    log_error "K3S_TOKEN is required. Get it from /var/lib/rancher/k3s/server/node-token on the server."
  fi
  # Basic URL validation
  [[ "$K3S_URL" =~ ^https?:// ]] || log_error "K3S_URL must start with https://"
}

# ── Connectivity check ─────────────────────────────────────────────────────────

check_connectivity() {
  log_info "Checking connectivity to $K3S_URL..."
  local server_host
  server_host=$(echo "$K3S_URL" | sed -E 's|https?://([^:/]+).*|\1|')
  local server_port
  server_port=$(echo "$K3S_URL" | sed -E 's|.*:([0-9]+).*|\1|')
  server_port="${server_port:-6443}"

  if ! timeout 5 bash -c ">/dev/tcp/${server_host}/${server_port}" 2>/dev/null; then
    log_error "Cannot reach $K3S_URL — check firewall rules (port 6443 must be open from agent to server)"
  fi
  log_ok "Server is reachable"
}

# ── k3s agent ──────────────────────────────────────────────────────────────────

install_k3s_agent() {
  log_section "k3s Agent Node ($AGENT_NAME)"

  if systemctl is-active --quiet k3s-agent; then
    log_ok "k3s-agent already running"
    return
  fi

  local env_args="K3S_URL=${K3S_URL} K3S_TOKEN=${K3S_TOKEN}"
  [[ -n "$K3S_VERSION" ]] && env_args="${env_args} INSTALL_K3S_VERSION=${K3S_VERSION}"

  local exec_args="agent --node-name ${AGENT_NAME}"

  log_info "Joining cluster as worker node..."
  eval "curl -sfL https://get.k3s.io | ${env_args} INSTALL_K3S_EXEC=\"${exec_args}\" sh -s -"

  systemctl enable --now k3s-agent
  log_ok "k3s agent joined cluster"
}

# ── Verify from server ─────────────────────────────────────────────────────────

print_verification() {
  log_section "Agent Node Joined"
  echo -e "${CYAN}Verify node joined from the server with:${NC}"
  echo -e "  KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes"
  echo ""
  echo -e "${GREEN}Expected output: both '${DEV_CLUSTER_NAME}-server' and '${AGENT_NAME}' in Ready state${NC}"
  echo ""
  echo -e "${YELLOW}Next: import this cluster into Rancher with 03-import-cluster.sh${NC}"
  echo -e "${YELLOW}      (run from the SERVER node, or any machine with kubeconfig access to the dev cluster)${NC}"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "Dev k3s Agent Setup"
  log_info "Server URL:  $K3S_URL"
  log_info "Agent name:  $AGENT_NAME"
  echo ""

  validate_inputs
  check_connectivity
  install_k3s_agent
  print_verification
}

main "$@"
