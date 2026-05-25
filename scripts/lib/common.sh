#!/usr/bin/env bash
# Shared utilities for all Rancher management scripts.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
log_section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }

require_root() {
  [[ $EUID -eq 0 ]] || log_error "Run this script as root: sudo $0"
}

require_ubuntu() {
  [[ -f /etc/os-release ]] && source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || log_warn "Designed for Ubuntu; detected: ${PRETTY_NAME:-unknown}"
}

require_command() {
  command -v "$1" &>/dev/null || log_error "Required command not found: $1. Run 00-install-prerequisites.sh first."
}

wait_for_rollout() {
  local namespace="$1" deployment="$2" timeout="${3:-300}"
  log_info "Waiting for $deployment in $namespace (timeout: ${timeout}s)..."
  kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="${timeout}s"
}

wait_for_url() {
  local url="$1" timeout="${2:-300}" interval=10 elapsed=0
  log_info "Waiting for $url to respond..."
  until curl -fsSk --max-time 5 "$url" &>/dev/null; do
    elapsed=$((elapsed + interval))
    [[ $elapsed -ge $timeout ]] && log_error "Timed out waiting for $url"
    echo -n "."
    sleep $interval
  done
  echo ""
  log_ok "$url is responding"
}

# Prompt with a default value; prints default in brackets.
prompt_with_default() {
  local prompt="$1" default="$2" varname="$3"
  read -rp "${prompt} [${default}]: " value
  printf -v "$varname" '%s' "${value:-$default}"
}
