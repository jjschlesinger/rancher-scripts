#!/usr/bin/env bash
# Install Rancher Monitoring (Prometheus + Grafana + Alertmanager) via Helm.
#
# This installs monitoring on the LOCAL cluster (Rancher management cluster by default).
# To monitor customer clusters, use Rancher's UI:
#   Cluster → Apps → Charts → Monitoring
#   (Rancher pushes the chart to the downstream cluster automatically.)
#
# What gets installed:
#   - kube-prometheus-stack (Prometheus, Grafana, Alertmanager, node-exporter)
#   - Rancher-specific dashboards for fleet overview
#   - Pre-configured alerts for node health, pod failures, PVC usage
#
# Usage:
#   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash 07-install-monitoring.sh
#
#   # For a specific downstream cluster (from an imported kubeconfig):
#   sudo KUBECONFIG=/root/.kube/clusters/dev.yaml \
#        GRAFANA_PASSWORD=MySecret bash 07-install-monitoring.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

[[ -f /root/.rancher-credentials ]] && source /root/.rancher-credentials

# ── Configuration ──────────────────────────────────────────────────────────────

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-cattle-monitoring-system}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"

# Retention
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
PROMETHEUS_STORAGE_SIZE="${PROMETHEUS_STORAGE_SIZE:-20Gi}"
ALERTMANAGER_STORAGE_SIZE="${ALERTMANAGER_STORAGE_SIZE:-2Gi}"

# Set to your SMTP details to enable email alerts, or leave blank
ALERTMANAGER_SMTP_HOST="${ALERTMANAGER_SMTP_HOST:-}"
ALERTMANAGER_SMTP_FROM="${ALERTMANAGER_SMTP_FROM:-}"
ALERTMANAGER_SMTP_TO="${ALERTMANAGER_SMTP_TO:-}"
ALERTMANAGER_SMTP_PASSWORD="${ALERTMANAGER_SMTP_PASSWORD:-}"

# Slack webhook for alert routing (optional)
ALERTMANAGER_SLACK_WEBHOOK="${ALERTMANAGER_SLACK_WEBHOOK:-}"
ALERTMANAGER_SLACK_CHANNEL="${ALERTMANAGER_SLACK_CHANNEL:-#alerts}"

# ── Validate ───────────────────────────────────────────────────────────────────

validate() {
  [[ -f "$KUBECONFIG" ]] || log_error "KUBECONFIG not found: $KUBECONFIG"
  require_command kubectl
  require_command helm

  if [[ -z "$GRAFANA_PASSWORD" ]]; then
    GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
    log_info "Generated Grafana password (save this): $GRAFANA_PASSWORD"
  fi
}

# ── Alertmanager config ────────────────────────────────────────────────────────

build_alertmanager_config() {
  local config
  config=$(cat <<'YAML'
global:
  resolve_timeout: 5m
route:
  receiver: 'null'
  group_by: ['alertname', 'cluster', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  routes:
  - match:
      severity: critical
    receiver: critical-alerts
  - match:
      severity: warning
    receiver: warning-alerts
receivers:
- name: 'null'
YAML
)

  # Append Slack receiver if configured
  if [[ -n "$ALERTMANAGER_SLACK_WEBHOOK" ]]; then
    config+=$(cat <<YAML

- name: critical-alerts
  slack_configs:
  - api_url: '${ALERTMANAGER_SLACK_WEBHOOK}'
    channel: '${ALERTMANAGER_SLACK_CHANNEL}'
    title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
    text: |
      {{ range .Alerts }}
      Cluster: {{ .Labels.cluster }}
      Namespace: {{ .Labels.namespace }}
      Summary: {{ .Annotations.summary }}
      Description: {{ .Annotations.description }}
      {{ end }}
- name: warning-alerts
  slack_configs:
  - api_url: '${ALERTMANAGER_SLACK_WEBHOOK}'
    channel: '${ALERTMANAGER_SLACK_CHANNEL}'
    title: '[WARNING] {{ .GroupLabels.alertname }}'
    text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'
YAML
)
  elif [[ -n "$ALERTMANAGER_SMTP_HOST" ]]; then
    config+=$(cat <<YAML

- name: critical-alerts
  email_configs:
  - to: '${ALERTMANAGER_SMTP_TO}'
    from: '${ALERTMANAGER_SMTP_FROM}'
    smarthost: '${ALERTMANAGER_SMTP_HOST}'
    auth_password: '${ALERTMANAGER_SMTP_PASSWORD}'
    send_resolved: true
- name: warning-alerts
  email_configs:
  - to: '${ALERTMANAGER_SMTP_TO}'
    from: '${ALERTMANAGER_SMTP_FROM}'
    smarthost: '${ALERTMANAGER_SMTP_HOST}'
    auth_password: '${ALERTMANAGER_SMTP_PASSWORD}'
YAML
)
  else
    config+=$'\n- name: critical-alerts\n- name: warning-alerts'
  fi

  echo "$config"
}

# ── Install monitoring stack ───────────────────────────────────────────────────

install_monitoring() {
  log_section "Rancher Monitoring Stack"
  export KUBECONFIG

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts \
    --force-update
  helm repo add rancher-charts https://charts.rancher.io \
    --force-update 2>/dev/null || true
  helm repo update

  kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  local alertmanager_config
  alertmanager_config=$(build_alertmanager_config)

  helm upgrade --install rancher-monitoring prometheus-community/kube-prometheus-stack \
    --namespace "$MONITORING_NAMESPACE" \
    --create-namespace \
    --set grafana.adminPassword="$GRAFANA_PASSWORD" \
    --set grafana.ingress.enabled=true \
    --set grafana.ingress.ingressClassName=nginx \
    --set "grafana.ingress.hosts[0]=grafana.$(hostname -I | awk '{print $1}').nip.io" \
    --set prometheus.prometheusSpec.retention="$PROMETHEUS_RETENTION" \
    --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=$PROMETHEUS_STORAGE_SIZE" \
    --set "alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=$ALERTMANAGER_STORAGE_SIZE" \
    --set "alertmanager.config=$(echo "$alertmanager_config" | base64 -w0)" \
    --set prometheus.prometheusSpec.externalLabels.cluster="$(kubectl config current-context 2>/dev/null | head -1)" \
    --set kubeControllerManager.enabled=false \
    --set kubeScheduler.enabled=false \
    --set kubeEtcd.enabled=false \
    --wait --timeout 10m

  log_ok "Monitoring stack installed"
}

# ── Install additional Rancher dashboards ──────────────────────────────────────

install_dashboards() {
  log_section "Grafana Dashboards"
  export KUBECONFIG

  # Fleet overview dashboard (multi-cluster summary)
  kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: rancher-fleet-overview
  namespace: cattle-monitoring-system
  labels:
    grafana_dashboard: "1"
data:
  fleet-overview.json: |
    {
      "title": "Fleet Overview",
      "uid": "fleet-overview",
      "panels": [],
      "schemaVersion": 37,
      "version": 1,
      "description": "Multi-cluster fleet health overview. Import dashboards 315 (K8s overview) and 13332 (K8s cluster) from grafana.com for full coverage."
    }
EOF

  log_ok "Base dashboards configured"
  log_info "Import these dashboards from grafana.com in the Grafana UI:"
  log_info "  315  — Kubernetes cluster monitoring"
  log_info "  13332 — Kubernetes cluster (community)"
  log_info "  7249  — Kubernetes Deployment Statefulset Daemonset"
}

# ── Create PodDisruptionBudget alerts ──────────────────────────────────────────

install_custom_alerts() {
  log_section "Custom Alert Rules"
  export KUBECONFIG

  kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: rancher-saas-alerts
  namespace: cattle-monitoring-system
  labels:
    release: rancher-monitoring
spec:
  groups:
  - name: saas.node
    interval: 30s
    rules:
    - alert: NodeNotReady
      expr: kube_node_status_condition{condition="Ready",status="true"} == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Node {{ $labels.node }} is NotReady"
        description: "Node has been NotReady for more than 5 minutes in cluster {{ $labels.cluster }}"

    - alert: NodeHighMemoryUsage
      expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "High memory usage on {{ $labels.instance }}"
        description: "Memory usage is {{ $value | humanizePercentage }}"

  - name: saas.workloads
    interval: 60s
    rules:
    - alert: DeploymentReplicasMismatch
      expr: kube_deployment_spec_replicas != kube_deployment_status_available_replicas
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} replica mismatch"
        description: "Expected {{ $value }} replicas, have {{ $labels.available }}"

    - alert: PodCrashLooping
      expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 5
      for: 0m
      labels:
        severity: critical
      annotations:
        summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} is crash looping"
        description: "Restarted {{ $value }} times in the last 15 minutes"

  - name: saas.storage
    interval: 60s
    rules:
    - alert: PVCUsageHigh
      expr: (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 80
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} is {{ $value | humanizePercentage }} full"
EOF

  log_ok "Custom alert rules installed"
}

# ── Print summary ──────────────────────────────────────────────────────────────

print_summary() {
  local grafana_host
  grafana_host="grafana.$(hostname -I | awk '{print $1}').nip.io"

  log_section "Monitoring Ready"
  echo -e "${GREEN}Grafana URL:      ${BOLD}https://${grafana_host}${NC}"
  echo -e "${GREEN}Grafana user:     ${BOLD}admin${NC}"
  echo -e "${GREEN}Grafana password: ${BOLD}${GRAFANA_PASSWORD}${NC}"
  echo ""
  echo -e "${CYAN}Prometheus and Alertmanager are ClusterIP services.${NC}"
  echo -e "${CYAN}Access via kubectl port-forward or the Rancher UI embedded dashboards.${NC}"
  echo ""
  echo -e "${YELLOW}To monitor a customer cluster:${NC}"
  echo -e "  Rancher UI → Cluster → Apps → Charts → Monitoring"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  log_section "Monitoring Installation"
  validate
  install_monitoring
  install_dashboards
  install_custom_alerts
  print_summary
}

main "$@"
