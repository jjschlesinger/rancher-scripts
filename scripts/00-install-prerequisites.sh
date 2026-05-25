#!/usr/bin/env bash
# Install all tools required for Rancher management:
#   Docker CE, kubectl, Helm, k9s, Rancher CLI, Azure CLI, AWS CLI v2, jq, etc.
#
# Usage: sudo bash 00-install-prerequisites.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_ubuntu

# ── System utilities ───────────────────────────────────────────────────────────

install_system_packages() {
  log_section "System Packages"
  apt-get update -qq
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    jq \
    git \
    unzip \
    openssl \
    htop \
    net-tools \
    nfs-common \
    open-iscsi \
    socat \
    conntrack \
    ipset
  log_ok "System packages installed"
}

# ── Docker ─────────────────────────────────────────────────────────────────────

install_docker() {
  log_section "Docker CE"
  if command -v docker &>/dev/null; then
    log_ok "Docker already installed: $(docker --version)"
    return
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log_ok "Docker installed: $(docker --version)"
  log_info "Add your user to docker group: sudo usermod -aG docker \$USER"
}

# ── kubectl ────────────────────────────────────────────────────────────────────

install_kubectl() {
  log_section "kubectl"
  if command -v kubectl &>/dev/null; then
    log_ok "kubectl already installed: $(kubectl version --client 2>/dev/null | head -1)"
    return
  fi

  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
  log_ok "kubectl installed: $KUBECTL_VERSION"
}

# ── Helm ───────────────────────────────────────────────────────────────────────

install_helm() {
  log_section "Helm 3"
  if command -v helm &>/dev/null; then
    log_ok "Helm already installed: $(helm version --short)"
    return
  fi

  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  log_ok "Helm installed: $(helm version --short)"
}

# ── k9s ────────────────────────────────────────────────────────────────────────

install_k9s() {
  log_section "k9s (cluster TUI)"
  if command -v k9s &>/dev/null; then
    log_ok "k9s already installed"
    return
  fi

  K9S_VERSION=$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
    | jq -r '.tag_name')
  curl -fsSL \
    "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
    | tar -xzC /usr/local/bin k9s
  log_ok "k9s installed: $K9S_VERSION"
}

# ── Rancher CLI ────────────────────────────────────────────────────────────────

install_rancher_cli() {
  log_section "Rancher CLI"
  if command -v rancher &>/dev/null; then
    log_ok "Rancher CLI already installed: $(rancher --version)"
    return
  fi

  RANCHER_CLI_VER=$(curl -fsSL https://api.github.com/repos/rancher/cli/releases/latest \
    | jq -r '.tag_name')
  TARBALL="rancher-linux-amd64-${RANCHER_CLI_VER}.tar.xz"
  curl -fsSL \
    "https://github.com/rancher/cli/releases/download/${RANCHER_CLI_VER}/${TARBALL}" \
    -o /tmp/rancher-cli.tar.xz
  tar -xJf /tmp/rancher-cli.tar.xz -C /tmp
  mv /tmp/rancher-${RANCHER_CLI_VER}/rancher /usr/local/bin/rancher
  chmod +x /usr/local/bin/rancher
  rm -rf /tmp/rancher-cli.tar.xz "/tmp/rancher-${RANCHER_CLI_VER}"
  log_ok "Rancher CLI installed: $(rancher --version)"
}

# ── Azure CLI ──────────────────────────────────────────────────────────────────

install_azure_cli() {
  log_section "Azure CLI (for AKS)"
  if command -v az &>/dev/null; then
    log_ok "Azure CLI already installed: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
    return
  fi

  curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
  log_ok "Azure CLI installed: $(az version --query '"azure-cli"' -o tsv)"
}

# ── AWS CLI ────────────────────────────────────────────────────────────────────

install_aws_cli() {
  log_section "AWS CLI v2 (for EKS)"
  if command -v aws &>/dev/null; then
    log_ok "AWS CLI already installed: $(aws --version)"
    return
  fi

  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
  log_ok "AWS CLI installed: $(aws --version)"
}

# ── kubectx / kubens ───────────────────────────────────────────────────────────

install_kubectx() {
  log_section "kubectx + kubens"
  if command -v kubectx &>/dev/null; then
    log_ok "kubectx already installed"
    return
  fi

  KCX_VER=$(curl -fsSL https://api.github.com/repos/ahmetb/kubectx/releases/latest \
    | jq -r '.tag_name')
  curl -fsSL \
    "https://github.com/ahmetb/kubectx/releases/download/${KCX_VER}/kubectx_${KCX_VER}_linux_x86_64.tar.gz" \
    | tar -xzC /usr/local/bin kubectx
  curl -fsSL \
    "https://github.com/ahmetb/kubectx/releases/download/${KCX_VER}/kubens_${KCX_VER}_linux_x86_64.tar.gz" \
    | tar -xzC /usr/local/bin kubens
  log_ok "kubectx + kubens installed: $KCX_VER"
}

# ── Helm repos ─────────────────────────────────────────────────────────────────

configure_helm_repos() {
  log_section "Helm Repositories"
  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
  helm repo add jetstack https://charts.jetstack.io
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update
  log_ok "Helm repos configured"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "Rancher Prerequisites Installer"
  install_system_packages
  install_docker
  install_kubectl
  install_helm
  install_k9s
  install_rancher_cli
  install_azure_cli
  install_aws_cli
  install_kubectx
  configure_helm_repos

  log_section "All prerequisites installed"
  log_ok "Run 01-install-rancher-server.sh next"
}

main "$@"
