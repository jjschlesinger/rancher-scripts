#!/usr/bin/env bash
# Provision a 3-node RKE2 HA cluster for on-premises deployments (Customer C).
#
# RKE2 is Rancher's production-grade Kubernetes distribution — FIPS-compliant,
# hardened, and recommended over k3s for customer-facing on-prem workloads.
#
# Node layout (run this script once per node with the appropriate NODE_ROLE):
#
#   Node 1  NODE_ROLE=init-server   Bootstraps the cluster. Runs etcd + control plane.
#   Node 2  NODE_ROLE=join-server   Joins Node 1. Adds etcd member (3-node quorum).
#   Node 3  NODE_ROLE=join-server   Joins Node 1. Adds etcd member (3-node quorum).
#
#   All 3 server nodes are schedulable by default.
#   For dedicated workers, run with NODE_ROLE=agent on additional machines.
#
# HA API endpoint:
#   kube-vip provides a floating VIP across the 3 server nodes so Rancher and
#   kubectl always have a stable API address even if one server is down.
#   Requires CLUSTER_VIP set to an unused IP on the same L2 subnet.
#
# Firewall ports required between nodes:
#   TCP 9345  — RKE2 node registration
#   TCP 6443  — Kubernetes API
#   TCP 2379-2380 — etcd peer/client
#   UDP 8472  — VXLAN (flannel CNI)
#   TCP 10250 — kubelet metrics
#   TCP 4240  — Cilium health (if using Cilium CNI)
#
# Usage — run sequentially:
#
#   # Node 1 (init):
#   sudo CLUSTER_NAME=customer-c \
#        CLUSTER_VIP=10.0.1.50 \
#        bash 08-provision-rke2-onprem.sh
#
#   # Node 2 & 3 (after Node 1 prints "cluster ready"):
#   sudo NODE_ROLE=join-server \
#        CLUSTER_NAME=customer-c \
#        INIT_SERVER_IP=10.0.1.10 \
#        CLUSTER_TOKEN=<token printed by Node 1> \
#        CLUSTER_VIP=10.0.1.50 \
#        bash 08-provision-rke2-onprem.sh
#
#   # Import into Rancher (run from Rancher server after all 3 nodes are ready):
#   source /root/.rancher-credentials
#   CLUSTER_DISPLAY_NAME=customer-c \
#   CUSTOMER_LABEL=customer-c \
#   ENVIRONMENT_LABEL=prod \
#   CLOUD_LABEL=k8s \
#   KUBECONFIG=/root/.kube/clusters/customer-c.yaml \
#   bash 03-import-cluster.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_ubuntu

# ── Configuration ──────────────────────────────────────────────────────────────

NODE_ROLE="${NODE_ROLE:-init-server}"       # init-server | join-server | agent
CLUSTER_NAME="${CLUSTER_NAME:-customer-c}"
RKE2_VERSION="${RKE2_VERSION:-}"            # empty = latest stable
CLUSTER_TOKEN="${CLUSTER_TOKEN:-}"          # auto-generated on init-server if blank

# Networking
CLUSTER_VIP="${CLUSTER_VIP:-}"             # Virtual IP for HA API endpoint (kube-vip)
INIT_SERVER_IP="${INIT_SERVER_IP:-}"       # IP of Node 1 — required for join-server/agent
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

# CNI: canal (default, RKE2 built-in) | calico | cilium
CNI="${CNI:-canal}"

# kube-vip: set INSTALL_KUBEVIP=false to skip (if you have a hardware LB)
INSTALL_KUBEVIP="${INSTALL_KUBEVIP:-true}"
KUBEVIP_INTERFACE="${KUBEVIP_INTERFACE:-}"  # auto-detected if blank

# Paths
RKE2_CONFIG_DIR="/etc/rancher/rke2"
RKE2_CONFIG_FILE="${RKE2_CONFIG_DIR}/config.yaml"
RKE2_MANIFESTS_DIR="/var/lib/rancher/rke2/server/manifests"
KUBECONFIG_PATH="${RKE2_CONFIG_DIR}/rke2.yaml"
CREDS_FILE="/root/.rke2-${CLUSTER_NAME}"

# ── Pre-flight checks ──────────────────────────────────────────────────────────

preflight() {
  log_section "Pre-flight Checks"

  # CPU
  local cpus
  cpus=$(nproc)
  [[ $cpus -ge 2 ]] || log_error "Minimum 2 CPUs required; detected $cpus"
  log_ok "CPU: $cpus cores"

  # RAM
  local ram_kb ram_gb
  ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  ram_gb=$((ram_kb / 1024 / 1024))
  [[ $ram_gb -ge 4 ]] || log_error "Minimum 4 GB RAM required; detected ${ram_gb} GB"
  log_ok "RAM: ${ram_gb} GB"

  # Disk
  local disk_avail_gb
  disk_avail_gb=$(df / --output=avail -BG | tail -1 | tr -d 'G')
  [[ $disk_avail_gb -ge 20 ]] || log_warn "Low disk space: ${disk_avail_gb} GB free (recommend ≥20 GB)"
  log_ok "Disk: ${disk_avail_gb} GB free"

  # Hostname
  log_info "Node IP: $NODE_IP"
  log_info "Role:    $NODE_ROLE"

  # Validate NODE_ROLE
  case "$NODE_ROLE" in
    init-server|join-server|agent) ;;
    *) log_error "NODE_ROLE must be init-server, join-server, or agent — got: $NODE_ROLE" ;;
  esac

  # join-server and agent require INIT_SERVER_IP and CLUSTER_TOKEN
  if [[ "$NODE_ROLE" != "init-server" ]]; then
    [[ -n "$INIT_SERVER_IP" ]] || log_error "INIT_SERVER_IP is required for NODE_ROLE=$NODE_ROLE"
    [[ -n "$CLUSTER_TOKEN"  ]] || log_error "CLUSTER_TOKEN is required for NODE_ROLE=$NODE_ROLE"
  fi
}

# ── Kernel / OS hardening (RKE2 CIS requirements) ─────────────────────────────

configure_os() {
  log_section "OS Configuration"

  # Disable swap (Kubernetes requirement)
  swapoff -a
  sed -i '/\sswap\s/s/^/#/' /etc/fstab
  log_ok "Swap disabled"

  # Enable required kernel modules
  cat > /etc/modules-load.d/rke2.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay br_netfilter

  # Kernel network parameters
  cat > /etc/sysctl.d/99-rke2.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system -q
  log_ok "Kernel parameters configured"

  # open-iscsi for Longhorn (if added later)
  apt-get install -y -q open-iscsi nfs-common curl jq
  systemctl enable --now iscsid 2>/dev/null || true
  log_ok "Storage prerequisites installed"
}

# ── Generate or validate cluster token ────────────────────────────────────────

prepare_token() {
  if [[ "$NODE_ROLE" == "init-server" && -z "$CLUSTER_TOKEN" ]]; then
    CLUSTER_TOKEN=$(openssl rand -hex 32)
    log_info "Generated cluster token: $CLUSTER_TOKEN"
  fi
}

# ── Detect network interface for kube-vip ─────────────────────────────────────

detect_interface() {
  if [[ -z "$KUBEVIP_INTERFACE" ]]; then
    KUBEVIP_INTERFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
    [[ -n "$KUBEVIP_INTERFACE" ]] || KUBEVIP_INTERFACE="eth0"
  fi
  log_info "Network interface: $KUBEVIP_INTERFACE"
}

# ── Write RKE2 config ──────────────────────────────────────────────────────────

write_config() {
  log_section "RKE2 Configuration"
  mkdir -p "$RKE2_CONFIG_DIR"

  local tls_sans=""
  tls_sans+="  - ${NODE_IP}"
  [[ -n "$CLUSTER_VIP"      ]] && tls_sans+=$'\n'"  - ${CLUSTER_VIP}"
  [[ -n "$INIT_SERVER_IP"   ]] && tls_sans+=$'\n'"  - ${INIT_SERVER_IP}"

  local cni_config=""
  if [[ "$CNI" != "canal" ]]; then
    cni_config="cni: ${CNI}"
  fi

  case "$NODE_ROLE" in

    init-server)
      cat > "$RKE2_CONFIG_FILE" <<EOF
# RKE2 init server — ${CLUSTER_NAME}
cluster-init: true
token: ${CLUSTER_TOKEN}
node-name: ${CLUSTER_NAME}-server-1
node-ip: ${NODE_IP}
tls-san:
${tls_sans}
${cni_config}
# Audit log for CIS compliance
kube-apiserver-arg:
  - audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log
  - audit-log-maxage=30
  - audit-log-maxbackup=10
  - audit-log-maxsize=100
EOF
      ;;

    join-server)
      local server_num
      server_num=$(date +%s | tail -c 4)
      cat > "$RKE2_CONFIG_FILE" <<EOF
# RKE2 join server — ${CLUSTER_NAME}
server: https://${INIT_SERVER_IP}:9345
token: ${CLUSTER_TOKEN}
node-name: ${CLUSTER_NAME}-server-${server_num}
node-ip: ${NODE_IP}
tls-san:
${tls_sans}
${cni_config}
kube-apiserver-arg:
  - audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log
  - audit-log-maxage=30
  - audit-log-maxbackup=10
  - audit-log-maxsize=100
EOF
      ;;

    agent)
      local agent_num
      agent_num=$(date +%s | tail -c 4)
      cat > "$RKE2_CONFIG_FILE" <<EOF
# RKE2 agent — ${CLUSTER_NAME}
server: https://${INIT_SERVER_IP}:9345
token: ${CLUSTER_TOKEN}
node-name: ${CLUSTER_NAME}-worker-${agent_num}
node-ip: ${NODE_IP}
EOF
      ;;
  esac

  chmod 600 "$RKE2_CONFIG_FILE"
  log_ok "Config written to $RKE2_CONFIG_FILE"
}

# ── kube-vip static pod manifest ──────────────────────────────────────────────

install_kubevip() {
  [[ "$INSTALL_KUBEVIP" != "true"   ]] && return
  [[ "$NODE_ROLE" == "agent"        ]] && return
  [[ -z "$CLUSTER_VIP"              ]] && {
    log_warn "CLUSTER_VIP not set — skipping kube-vip. Set it for HA API endpoint."
    return
  }

  log_section "kube-vip (HA Virtual IP: $CLUSTER_VIP)"
  detect_interface

  mkdir -p "$RKE2_MANIFESTS_DIR"

  # kube-vip runs as a DaemonSet on control-plane nodes
  local kvip_version
  kvip_version=$(curl -fsSL https://api.github.com/repos/kube-vip/kube-vip/releases/latest \
    | jq -r '.tag_name' 2>/dev/null || echo "v0.8.9")

  cat > "${RKE2_MANIFESTS_DIR}/kube-vip.yaml" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-vip-ds
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-vip-ds
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-vip-ds
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-vip-ds
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
      hostNetwork: true
      serviceAccountName: kube-vip
      containers:
      - name: kube-vip
        image: ghcr.io/kube-vip/kube-vip:${kvip_version}
        imagePullPolicy: IfNotPresent
        args:
        - manager
        env:
        - name: vip_arp
          value: "true"
        - name: port
          value: "6443"
        - name: vip_interface
          value: "${KUBEVIP_INTERFACE}"
        - name: vip_cidr
          value: "32"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: kube-system
        - name: vip_ddns
          value: "false"
        - name: svc_enable
          value: "true"
        - name: vip_leaderelection
          value: "true"
        - name: vip_leaseduration
          value: "5"
        - name: vip_renewdeadline
          value: "3"
        - name: vip_retryperiod
          value: "1"
        - name: address
          value: "${CLUSTER_VIP}"
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-vip
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kube-vip-role
rules:
- apiGroups: [""]
  resources: [nodes, services, endpoints, events, configmaps]
  verbs: [get, list, watch, update, patch, create]
- apiGroups: [coordination.k8s.io]
  resources: [leases]
  verbs: [get, list, watch, create, update]
- apiGroups: [discovery.k8s.io]
  resources: [endpointslices]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-vip-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-vip-role
subjects:
- kind: ServiceAccount
  name: kube-vip
  namespace: kube-system
EOF

  log_ok "kube-vip manifest written — VIP: $CLUSTER_VIP on $KUBEVIP_INTERFACE"
}

# ── Install RKE2 ───────────────────────────────────────────────────────────────

install_rke2() {
  log_section "RKE2 Installation"

  local env_args=""
  [[ -n "$RKE2_VERSION" ]] && env_args="INSTALL_RKE2_VERSION=${RKE2_VERSION}"

  local type_flag="server"
  [[ "$NODE_ROLE" == "agent" ]] && type_flag="agent"

  log_info "Installing RKE2 ($type_flag)..."
  eval "curl -sfL https://get.rke2.io | ${env_args} INSTALL_RKE2_TYPE=${type_flag} sh -"
  log_ok "RKE2 binary installed"
}

# ── Start RKE2 service ─────────────────────────────────────────────────────────

start_rke2() {
  log_section "Starting RKE2"

  local service="rke2-server"
  [[ "$NODE_ROLE" == "agent" ]] && service="rke2-agent"

  systemctl enable "$service"
  systemctl start "$service"

  log_info "Waiting for $service to be active..."
  local attempts=0
  until systemctl is-active --quiet "$service"; do
    sleep 5
    attempts=$((attempts + 1))
    [[ $attempts -ge 24 ]] && log_error "RKE2 service failed to start. Check: journalctl -u $service -f"
    echo -n "."
  done
  echo ""
  log_ok "$service is running"
}

# ── Wait for node Ready (init-server only) ─────────────────────────────────────

wait_for_ready() {
  [[ "$NODE_ROLE" != "init-server" ]] && return

  log_section "Waiting for Node Ready"
  export KUBECONFIG="$KUBECONFIG_PATH"
  export PATH="/var/lib/rancher/rke2/bin:$PATH"

  local attempts=0
  until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    sleep 10
    attempts=$((attempts + 1))
    [[ $attempts -ge 30 ]] && log_error "Node did not become Ready in 5 minutes"
    echo -n "."
  done
  echo ""

  kubectl get nodes -o wide
  log_ok "Node is Ready"
}

# ── Configure kubectl access ───────────────────────────────────────────────────

configure_kubectl() {
  [[ "$NODE_ROLE" == "agent" ]] && return

  log_section "kubectl Configuration"

  # Symlink kubectl
  ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl 2>/dev/null || true

  # Add to PATH permanently
  cat > /etc/profile.d/rke2.sh <<'EOF'
export PATH="/var/lib/rancher/rke2/bin:$PATH"
export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
EOF

  # Root user convenience
  mkdir -p /root/.kube
  cp "$KUBECONFIG_PATH" /root/.kube/config
  chmod 600 /root/.kube/config

  # Save a copy keyed by cluster name for use with 03-import-cluster.sh
  mkdir -p /root/.kube/clusters
  cp "$KUBECONFIG_PATH" "/root/.kube/clusters/${CLUSTER_NAME}.yaml"
  chmod 600 "/root/.kube/clusters/${CLUSTER_NAME}.yaml"

  log_ok "kubeconfig saved to /root/.kube/config and /root/.kube/clusters/${CLUSTER_NAME}.yaml"
}

# ── Save credentials file ──────────────────────────────────────────────────────

save_credentials() {
  cat > "$CREDS_FILE" <<EOF
# RKE2 cluster credentials — ${CLUSTER_NAME}
CLUSTER_NAME=${CLUSTER_NAME}
NODE_ROLE=${NODE_ROLE}
CLUSTER_TOKEN=${CLUSTER_TOKEN}
INIT_SERVER_IP=${NODE_IP}
CLUSTER_VIP=${CLUSTER_VIP}
KUBECONFIG=/root/.kube/clusters/${CLUSTER_NAME}.yaml
EOF
  chmod 600 "$CREDS_FILE"
  log_ok "Credentials saved to $CREDS_FILE"
}

# ── Print completion summary ───────────────────────────────────────────────────

print_summary() {
  log_section "RKE2 Node Ready"

  case "$NODE_ROLE" in

    init-server)
      echo -e "${GREEN}Cluster: ${BOLD}${CLUSTER_NAME}${NC}"
      echo -e "${GREEN}Node IP: ${BOLD}${NODE_IP}${NC}"
      [[ -n "$CLUSTER_VIP" ]] && echo -e "${GREEN}API VIP: ${BOLD}${CLUSTER_VIP}:6443${NC}"
      echo ""
      echo -e "${CYAN}── Join Node 2 & 3 ─────────────────────────────────────────────${NC}"
      echo -e "sudo NODE_ROLE=join-server \\"
      echo -e "     CLUSTER_NAME=${CLUSTER_NAME} \\"
      echo -e "     INIT_SERVER_IP=${NODE_IP} \\"
      echo -e "     CLUSTER_TOKEN=${CLUSTER_TOKEN} \\"
      [[ -n "$CLUSTER_VIP" ]] && echo -e "     CLUSTER_VIP=${CLUSTER_VIP} \\"
      echo -e "     bash 08-provision-rke2-onprem.sh"
      echo ""
      echo -e "${CYAN}── Import into Rancher (after all 3 nodes are Ready) ───────────${NC}"
      echo -e "source /root/.rancher-credentials"
      echo -e "CLUSTER_DISPLAY_NAME=${CLUSTER_NAME} \\"
      echo -e "CUSTOMER_LABEL=${CLUSTER_NAME} \\"
      echo -e "ENVIRONMENT_LABEL=prod \\"
      echo -e "CLOUD_LABEL=k8s \\"
      echo -e "KUBECONFIG=/root/.kube/clusters/${CLUSTER_NAME}.yaml \\"
      echo -e "bash 03-import-cluster.sh"
      echo ""
      echo -e "${YELLOW}Credentials saved to: $CREDS_FILE${NC}"
      ;;

    join-server)
      echo -e "${GREEN}Joined cluster ${BOLD}${CLUSTER_NAME}${NC} as a server node"
      echo -e "${GREEN}Node IP: ${BOLD}${NODE_IP}${NC}"
      echo ""
      echo -e "${CYAN}Verify from Node 1:${NC}"
      echo -e "  KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl get nodes"
      ;;

    agent)
      echo -e "${GREEN}Joined cluster ${BOLD}${CLUSTER_NAME}${NC} as a worker node"
      echo -e "${GREEN}Node IP: ${BOLD}${NODE_IP}${NC}"
      echo ""
      echo -e "${CYAN}Verify from a server node:${NC}"
      echo -e "  KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl get nodes"
      ;;
  esac
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "RKE2 On-Premises Cluster — ${CLUSTER_NAME}"
  log_info "Role: $NODE_ROLE  |  Node IP: $NODE_IP"
  echo ""

  preflight
  configure_os
  prepare_token
  write_config
  install_kubevip
  install_rke2
  start_rke2
  wait_for_ready
  configure_kubectl

  [[ "$NODE_ROLE" == "init-server" ]] && save_credentials

  print_summary
}

main "$@"
