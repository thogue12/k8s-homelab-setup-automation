#!/usr/bin/env bash
#
# Stage 2 (control-plane): kubeadm init + user kubeconfig + taint removal.
# Migrated from bootStrap-K8s.bash §4 and make-kube-work-for-current-user.sh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

stage_init "control-plane"

# Resolve the invoking (non-root) user and their home, even under sudo.
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  KUBE_USER="${SUDO_USER}"
else
  KUBE_USER="$(id -un)"
fi
KUBE_UID="$(id -u "${KUBE_USER}")"
KUBE_GID="$(id -g "${KUBE_USER}")"
KUBE_HOME="$(getent passwd "${KUBE_USER}" | cut -d: -f6)"
[ -n "${KUBE_HOME}" ] || die "could not resolve home directory for user '${KUBE_USER}'"

readonly ADMIN_CONF="/etc/kubernetes/admin.conf"

# Load .env so POD_CIDR (and any other persisted inputs) are in scope. Without
# this, resolve_pod_cidr sees POD_CIDR unset when the stage runs on its own and
# falls back to discovery/default — which caused kubeadm init to use the wrong
# pod CIDR instead of the one in .env.
env_load

# Run as root directly if already root, else via sudo.
sudo_if_needed() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Pod CIDR: resolve, defaulting to 10.244.0.0/16 at init time. NOT Calico's
# 192.168.0.0/16 default: that overlaps a typical 192.168.x home LAN, which
# makes pod->router/DNS traffic get routed into the overlay instead of NATed
# out, breaking all external DNS from pods. 10.244/16 avoids that collision.
POD_CIDR_RESOLVED="$(resolve_pod_cidr)"
if [ -z "${POD_CIDR_RESOLVED}" ]; then
  POD_CIDR_RESOLVED="10.244.0.0/16"
fi

# Already initialized when admin.conf exists, the API is healthy, or a control
# plane is demonstrably running on this node.
# NOTE: /etc/kubernetes is mode 700 root:root, so a bare '[ -f ... ]' is FALSE
# for a non-root caller even when admin.conf exists. Checking only that led to
# 'kubeadm init' being attempted against a LIVE cluster (ports 6443/10257/10259
# already in use). The extra probes below make that impossible.
control_plane_initialized() {
  # Cheapest, non-interactive probes first so we never prompt for a password
  # just to answer "is this already initialized?".
  [ -f "${ADMIN_CONF}" ] && return 0
  # A listening API server means a control plane is already up (no root needed).
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':6443'; then
    return 0
  fi
  # Passwordless sudo only; never blocks waiting on input.
  sudo -n test -f "${ADMIN_CONF}" 2>/dev/null && return 0
  sudo -n test -f /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null && return 0
  kubectl --kubeconfig "${ADMIN_CONF}" cluster-info >/dev/null 2>&1 && return 0
  return 1
}

if control_plane_initialized; then
  info "control plane already initialized; skipping 'kubeadm init'"
else
  require_cmd kubeadm "install the Kubernetes tools first (run the prereqs stage)"
  info "initializing control plane: kubeadm init --pod-network-cidr=${POD_CIDR_RESOLVED}"
  sudo_if_needed kubeadm init --pod-network-cidr="${POD_CIDR_RESOLVED}"
fi

sudo_if_needed test -f "${ADMIN_CONF}" \
  || die "a control plane appears to be running but ${ADMIN_CONF} is missing; the node is in a partial state. Reset it (sudo kubeadm reset -f) and re-run."

readonly KUBE_DIR="${KUBE_HOME}/.kube"
readonly KUBE_CONFIG="${KUBE_DIR}/config"

sudo_if_needed mkdir -p "${KUBE_DIR}"

# Back up any existing kubeconfig before overwriting.
if sudo_if_needed test -f "${KUBE_CONFIG}"; then
  BACKUP="${KUBE_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  info "backing up existing kubeconfig to ${BACKUP}"
  sudo_if_needed cp "${KUBE_CONFIG}" "${BACKUP}"
fi

info "installing admin kubeconfig at ${KUBE_CONFIG} (owner ${KUBE_USER}, mode 600)"
sudo_if_needed cp "${ADMIN_CONF}" "${KUBE_CONFIG}"
sudo_if_needed chown "${KUBE_UID}:${KUBE_GID}" "${KUBE_DIR}" "${KUBE_CONFIG}"
sudo_if_needed chmod 600 "${KUBE_CONFIG}"

# Remove the control-plane taint so the single node schedules workloads.
info "removing control-plane taint from all nodes (tolerant of 'not found')"
sudo_if_needed kubectl --kubeconfig "${ADMIN_CONF}" taint nodes --all \
  node-role.kubernetes.io/control-plane- 2>/dev/null || true

# Verify the cluster is reachable as the operator.
info "verifying 'kubectl get nodes' as ${KUBE_USER}"
run_as_user() {
  if [ "$(id -un)" = "${KUBE_USER}" ]; then
    "$@"
  else
    sudo -u "${KUBE_USER}" "$@"
  fi
}
if ! run_as_user env KUBECONFIG="${KUBE_CONFIG}" \
      kubectl get nodes >/dev/null 2>&1; then
  if ! sudo_if_needed kubectl --kubeconfig "${ADMIN_CONF}" get nodes >/dev/null 2>&1; then
    die "'kubectl get nodes' failed; inspect with: kubectl --kubeconfig ${ADMIN_CONF} get nodes; kubectl -n kube-system get pods"
  fi
  warn "kubectl worked via admin.conf but not as ${KUBE_USER}; check ${KUBE_CONFIG} ownership/permissions"
fi

info "control-plane stage complete (pod CIDR ${POD_CIDR_RESOLVED}, kubeconfig at ${KUBE_CONFIG})"
