#!/usr/bin/env bash
# Install k3s server node for the dev cluster.
# Run this on the FIRST dev cluster machine (the control plane node).
#
# After this script completes, run 02b-create-dev-k3s-agent.sh on the second machine.
#
# Usage:
#   sudo bash 02a-create-dev-k3s-server.sh
#   sudo DEV_CLUSTER_NAME=dev K3S_VERSION=v1.31.4+k3s1 bash 02a-create-dev-k3s-server.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

# ── Configuration ──────────────────────────────────────────────────────────────

DEV_CLUSTER_NAME="${DEV_CLUSTER_NAME:-dev}"
K3S_VERSION="${K3S_VERSION:-}"   # empty = latest stable

# The IP/hostname that agent nodes will use to reach this server.
# Defaults to the primary non-loopback IP.
SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"

# CNI: flannel (default) | calico | cilium
CNI="${CNI:-flannel}"

# Optional: install Longhorn storage driver on the dev cluster
INSTALL_LONGHORN="${INSTALL_LONGHORN:-false}"

KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
CREDS_FILE="/root/.k3s-dev-server"

# ── k3s server ─────────────────────────────────────────────────────────────────

install_k3s_server() {
  log_section "k3s Server Node ($DEV_CLUSTER_NAME)"

  if systemctl is-active --quiet k3s; then
    log_ok "k3s server already running: $(k3s --version | head -1)"
    return
  fi

  local env_args=""
  [[ -n "$K3S_VERSION" ]] && env_args="INSTALL_K3S_VERSION=${K3S_VERSION}"

  local exec_args="server"
  exec_args+=" --tls-san ${SERVER_IP}"
  exec_args+=" --node-name ${DEV_CLUSTER_NAME}-server"

  # Disable default ingress if we'll install our own
  exec_args+=" --disable traefik"

  if [[ "$CNI" != "flannel" ]]; then
    exec_args+=" --flannel-backend=none --disable-network-policy"
  fi

  log_info "Installing k3s server..."
  eval "curl -sfL https://get.k3s.io | ${env_args} INSTALL_K3S_EXEC=\"${exec_args}\" sh -s -"

  systemctl enable --now k3s
  log_ok "k3s server installed: $(k3s --version | head -1)"

  mkdir -p /root/.kube
  cp "$KUBECONFIG" /root/.kube/config
  chmod 600 /root/.kube/config
}

# ── CNI (optional alternatives) ────────────────────────────────────────────────

install_cni() {
  [[ "$CNI" == "flannel" ]] && return

  log_section "Installing CNI: $CNI"
  export KUBECONFIG

  case "$CNI" in
    calico)
      kubectl apply -f \
        https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml
      ;;
    cilium)
      require_command helm
      helm repo add cilium https://helm.cilium.io/ --force-update
      helm repo update
      helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --set operator.replicas=1 \
        --wait --timeout 5m
      ;;
    *)
      log_warn "Unknown CNI '$CNI', skipping"
      ;;
  esac
  log_ok "$CNI installed"
}

# ── Longhorn (optional) ────────────────────────────────────────────────────────

install_longhorn() {
  [[ "$INSTALL_LONGHORN" != "true" ]] && return

  log_section "Longhorn Distributed Storage"
  export KUBECONFIG

  # Longhorn requires open-iscsi
  apt-get install -y open-iscsi nfs-common
  systemctl enable --now iscsid

  helm repo add longhorn https://charts.longhorn.io --force-update
  helm repo update

  helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --wait --timeout 10m

  log_ok "Longhorn installed"
}

# ── Print join info ────────────────────────────────────────────────────────────

save_join_info() {
  local node_token
  node_token=$(cat /var/lib/rancher/k3s/server/node-token)

  cat > "$CREDS_FILE" <<EOF
# k3s dev cluster server credentials
DEV_CLUSTER_NAME=${DEV_CLUSTER_NAME}
K3S_SERVER_URL=https://${SERVER_IP}:6443
K3S_NODE_TOKEN=${node_token}
KUBECONFIG=${KUBECONFIG}
EOF
  chmod 600 "$CREDS_FILE"

  log_section "Dev Cluster Server Ready"
  echo -e "${GREEN}Server IP:   ${BOLD}${SERVER_IP}${NC}"
  echo -e "${GREEN}K3S URL:     ${BOLD}https://${SERVER_IP}:6443${NC}"
  echo -e "${GREEN}Node token:  ${BOLD}${node_token}${NC}"
  echo ""
  echo -e "${CYAN}Credentials saved to: $CREDS_FILE${NC}"
  echo ""
  echo -e "${YELLOW}On the agent/worker node, run:${NC}"
  echo -e "  sudo K3S_URL=https://${SERVER_IP}:6443 \\"
  echo -e "       K3S_TOKEN=${node_token} \\"
  echo -e "       bash 02b-create-dev-k3s-agent.sh"
}

# ── Label server node ──────────────────────────────────────────────────────────

label_server_node() {
  export KUBECONFIG
  kubectl label node "${DEV_CLUSTER_NAME}-server" \
    node-role.kubernetes.io/control-plane=true \
    environment=dev \
    cluster="${DEV_CLUSTER_NAME}" \
    --overwrite 2>/dev/null || true
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "Dev k3s Server Setup"
  log_info "Cluster name: $DEV_CLUSTER_NAME"
  log_info "Server IP:    $SERVER_IP"
  log_info "CNI:          $CNI"
  echo ""

  install_k3s_server
  install_cni
  install_longhorn
  label_server_node
  save_join_info

  log_ok "Dev server node ready. Run 02b-create-dev-k3s-agent.sh on the second node."
}

main "$@"
