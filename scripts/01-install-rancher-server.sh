#!/usr/bin/env bash
# Install Rancher on a fresh Ubuntu node using k3s as the management cluster.
#
# What this script does:
#   1. Installs k3s (single-node management cluster for Rancher)
#   2. Installs NGINX ingress controller
#   3. Installs cert-manager (TLS)
#   4. Installs Rancher via Helm
#   5. Bootstraps the admin account and prints credentials
#
# Requirements:
#   - Fresh Ubuntu 22.04/24.04 VM with ≥2 vCPU, ≥4 GB RAM
#   - Port 80 and 443 open (firewall/security group)
#   - A hostname with DNS pointing to this server's IP
#     (or use --tls-san with an IP for internal/self-signed use)
#
# Usage:
#   sudo bash 01-install-rancher-server.sh
#   sudo RANCHER_HOSTNAME=rancher.mycompany.com RANCHER_PASSWORD=MySecret bash 01-install-rancher-server.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root

# ── Configuration ──────────────────────────────────────────────────────────────
# Override any of these via environment variables before running.

# FQDN for Rancher UI — must resolve to this server's IP for Let's Encrypt.
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.$(hostname -I | awk '{print $1}').nip.io}"

# rancher-stable | rancher-latest | rancher-alpha
RANCHER_CHART_REPO="${RANCHER_CHART_REPO:-rancher-stable}"

# Pin to a specific version, e.g. "2.10.1", or "latest"
RANCHER_VERSION="${RANCHER_VERSION:-latest}"

# Initial admin password (min 12 chars). Leave blank to generate one.
RANCHER_PASSWORD="${RANCHER_PASSWORD:-}"

# letsEncrypt | rancher (self-signed)
RANCHER_TLS="${RANCHER_TLS:-rancher}"

# Let's Encrypt notification email (only used when RANCHER_TLS=letsEncrypt)
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@example.com}"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
K3S_VERSION="${K3S_VERSION:-}"   # empty = latest stable

KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ── k3s ────────────────────────────────────────────────────────────────────────

install_k3s() {
  log_section "k3s (management cluster)"

  if command -v k3s &>/dev/null && k3s check-config &>/dev/null 2>&1; then
    log_ok "k3s already running: $(k3s --version | head -1)"
    return
  fi

  local install_args="server --disable traefik --disable servicelb"
  # Allow SANs for IP-based access if no real DNS is set up
  install_args+=" --tls-san $(hostname -I | awk '{print $1}')"
  [[ -n "$RANCHER_HOSTNAME" ]] && install_args+=" --tls-san $RANCHER_HOSTNAME"

  local env_args=""
  [[ -n "$K3S_VERSION" ]] && env_args="INSTALL_K3S_VERSION=$K3S_VERSION"

  log_info "Installing k3s..."
  eval "curl -sfL https://get.k3s.io | ${env_args} INSTALL_K3S_EXEC=\"${install_args}\" sh -s -"

  systemctl enable --now k3s
  log_ok "k3s installed: $(k3s --version | head -1)"

  # Make kubeconfig available to non-root users
  mkdir -p /root/.kube
  cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
  chmod 600 /root/.kube/config
}

# ── NGINX Ingress ──────────────────────────────────────────────────────────────

install_nginx_ingress() {
  log_section "NGINX Ingress Controller"

  if kubectl get ns ingress-nginx &>/dev/null 2>&1; then
    log_ok "NGINX ingress already installed"
    return
  fi

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
  helm repo update

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.hostNetwork=true \
    --set controller.kind=DaemonSet \
    --set controller.service.type=ClusterIP \
    --wait --timeout 5m

  log_ok "NGINX ingress controller installed"
}

# ── cert-manager ───────────────────────────────────────────────────────────────

install_cert_manager() {
  log_section "cert-manager $CERT_MANAGER_VERSION"

  if kubectl get ns cert-manager &>/dev/null 2>&1; then
    log_ok "cert-manager already installed"
    return
  fi

  helm repo add jetstack https://charts.jetstack.io --force-update
  helm repo update

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --wait --timeout 5m

  log_ok "cert-manager installed"
}

# ── Rancher ────────────────────────────────────────────────────────────────────

install_rancher() {
  log_section "Rancher"

  helm repo add "$RANCHER_CHART_REPO" \
    "https://releases.rancher.com/server-charts/${RANCHER_CHART_REPO#rancher-}" \
    --force-update
  helm repo update

  local version_flag=""
  [[ "$RANCHER_VERSION" != "latest" ]] && version_flag="--version $RANCHER_VERSION"

  local tls_args=""
  if [[ "$RANCHER_TLS" == "letsEncrypt" ]]; then
    tls_args="--set ingress.tls.source=letsEncrypt --set letsEncrypt.email=$LETSENCRYPT_EMAIL --set letsEncrypt.ingress.class=nginx"
  else
    tls_args="--set ingress.tls.source=rancher"
  fi

  # shellcheck disable=SC2086
  helm upgrade --install rancher "$RANCHER_CHART_REPO/rancher" \
    --namespace cattle-system \
    --create-namespace \
    $version_flag \
    --set hostname="$RANCHER_HOSTNAME" \
    --set replicas=1 \
    --set ingress.ingressClassName=nginx \
    $tls_args \
    --wait --timeout 10m

  log_ok "Rancher helm chart deployed"
}

# ── Bootstrap admin account ────────────────────────────────────────────────────

bootstrap_rancher() {
  log_section "Bootstrapping Rancher Admin"

  # Wait for Rancher to become healthy
  wait_for_rollout cattle-system rancher 600

  local server_url="https://${RANCHER_HOSTNAME}"
  wait_for_url "$server_url/ping" 300

  # Get bootstrap password from secret
  local bootstrap_pw
  bootstrap_pw=$(kubectl get secret --namespace cattle-system bootstrap-secret \
    -o jsonpath='{.data.bootstrapPassword}' | base64 -d)

  # Generate a strong admin password if not supplied
  if [[ -z "$RANCHER_PASSWORD" ]]; then
    RANCHER_PASSWORD=$(openssl rand -base64 20 | tr -d '=/+' | head -c 24)
  fi

  # Login and set admin password via Rancher API
  log_info "Setting admin password via API..."
  local login_token
  login_token=$(curl -fsSk -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"${bootstrap_pw}\"}" \
    "${server_url}/v3-public/localProviders/local?action=login" \
    | jq -r '.token')

  [[ -z "$login_token" || "$login_token" == "null" ]] && \
    log_error "Failed to obtain login token — Rancher may not be fully ready yet."

  curl -fsSk -X POST \
    -H "Authorization: Bearer $login_token" \
    -H 'Content-Type: application/json' \
    -d "{\"currentPassword\":\"${bootstrap_pw}\",\"newPassword\":\"${RANCHER_PASSWORD}\"}" \
    "${server_url}/v3/users?action=changepassword" > /dev/null

  # Set server URL
  curl -fsSk -X PUT \
    -H "Authorization: Bearer $login_token" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"server-url\",\"value\":\"${server_url}\"}" \
    "${server_url}/v3/settings/server-url" > /dev/null

  # Create a permanent API token for scripts
  local api_token
  api_token=$(curl -fsSk -X POST \
    -H "Authorization: Bearer $login_token" \
    -H 'Content-Type: application/json' \
    -d '{"type":"token","description":"admin-scripts-token","ttl":0}' \
    "${server_url}/v3/tokens" | jq -r '.token')

  # Save credentials to a local file (restrict permissions)
  cat > /root/.rancher-credentials <<EOF
RANCHER_URL=${server_url}
RANCHER_TOKEN=${api_token}
RANCHER_PASSWORD=${RANCHER_PASSWORD}
EOF
  chmod 600 /root/.rancher-credentials

  log_section "Rancher is Ready"
  echo -e "${GREEN}URL:      ${BOLD}${server_url}${NC}"
  echo -e "${GREEN}Username: ${BOLD}admin${NC}"
  echo -e "${GREEN}Password: ${BOLD}${RANCHER_PASSWORD}${NC}"
  echo -e "${GREEN}API Token saved to: ${BOLD}/root/.rancher-credentials${NC}"
  echo ""
  echo -e "${YELLOW}IMPORTANT: Save these credentials in a secrets manager (Vault, AWS Secrets, etc.)${NC}"
}

# ── join-token helper ──────────────────────────────────────────────────────────

print_join_info() {
  local node_token
  node_token=$(cat /var/lib/rancher/k3s/server/node-token)
  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')

  log_section "k3s Node Join Information"
  echo -e "${CYAN}If you add worker nodes to the Rancher management cluster:${NC}"
  echo -e "  K3S_URL=https://${server_ip}:6443"
  echo -e "  K3S_TOKEN=${node_token}"
  echo ""
  echo -e "${YELLOW}NOTE: For production, run Rancher in a 3-node HA cluster (RKE2 recommended).${NC}"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "Rancher Server Installer"
  log_info "Hostname:    $RANCHER_HOSTNAME"
  log_info "TLS source:  $RANCHER_TLS"
  log_info "Rancher ver: $RANCHER_VERSION"
  echo ""

  export KUBECONFIG

  install_k3s
  install_nginx_ingress
  install_cert_manager
  install_rancher
  bootstrap_rancher
  print_join_info

  log_ok "Rancher installation complete. Next: run 02a-create-dev-k3s-server.sh on your dev node."
}

main "$@"
