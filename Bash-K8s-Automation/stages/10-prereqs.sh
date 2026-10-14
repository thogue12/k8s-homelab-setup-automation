#!/usr/bin/env bash
#
# Stage 1 (prereqs): node prep, containerd, kube tools. Migrated from
# install-k8s-prereqs.sh. Safe to re-run.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

stage_init "prereqs"

require_apt

# Target minor: K8S_MINOR override -> cluster -> kubeadm -> latest reviewed.
if [ -n "${K8S_MINOR:-}" ]; then
  K8S_MINOR="${K8S_MINOR#v}"
  K8S_MINOR="$(echo "${K8S_MINOR}" | cut -d. -f1,2)"
  info "using explicit K8S_MINOR=${K8S_MINOR}"
else
  _discovered="$(discover_cluster_minor)"
  if [ -n "${_discovered}" ]; then
    K8S_MINOR="${_discovered}"
    info "matched reachable cluster: ${K8S_MINOR}"
  else
    _discovered="$(discover_installed_kubeadm_minor)"
    if [ -n "${_discovered}" ]; then
      K8S_MINOR="${_discovered}"
      info "matched installed kubeadm: ${K8S_MINOR}"
    else
      K8S_MINOR="${LATEST_REVIEWED_MINOR}"
      info "no cluster or kubeadm found; using latest reviewed ${K8S_MINOR}"
    fi
  fi
fi
K8S_REPO_MINOR="v${K8S_MINOR}"

# Kernel modules + sysctl.
info "loading kernel modules and setting sysctl"
sudo tee /etc/modules-load.d/k8s.conf <<CONFIGEOF >/dev/null
overlay
br_netfilter
CONFIGEOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/k8s.conf <<CONFIGEOF >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
CONFIGEOF

sudo sysctl --system >/dev/null

# Disable swap.
info "disabling swap"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Install + configure containerd with the systemd cgroup driver.
info "installing and configuring containerd"
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg git containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

# Kubernetes tools (no Docker Engine).
info "installing Kubernetes components (${K8S_REPO_MINOR})"
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

# Verify.
if ! sudo systemctl is-active --quiet containerd; then
  die "containerd is not active; inspect with: systemctl status containerd && journalctl -u containerd -e"
fi
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  die "containerd is not using the systemd cgroup driver; expected 'SystemdCgroup = true' in /etc/containerd/config.toml"
fi

info "prereqs complete (Kubernetes ${K8S_REPO_MINOR}, containerd active with systemd cgroup driver)"
