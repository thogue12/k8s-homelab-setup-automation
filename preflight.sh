#!/usr/bin/env bash
#
# preflight.sh — desired-state scanner + up-front input collection.
#
#   ./preflight.sh --emit-needed             # print stages whose state is unmet
#   ./preflight.sh --collect-inputs STAGES   # collect .env inputs for those stages

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

stage_init "preflight"

# check name -> stage that reconciles it (the single edit point for extending the pipeline)
declare -A DESIRED_STAGE=(
  [apt_based]="prereqs"
  [kernel_modules]="prereqs"
  [sysctl_k8s]="prereqs"
  [swap_off]="prereqs"
  [containerd_systemd_cgroup]="prereqs"
  [kube_tools_held]="prereqs"
  [git_installed]="prereqs"
  [pod_cidr_no_lan_overlap]="control-plane"
  [control_plane_initialized]="control-plane"
  [kubeconfig_installed]="control-plane"
  [cp_taint_removed]="control-plane"
  [k8s_version_expected]="prereqs"
  [calico_available]="calico"
  [calico_version_expected]="calico"
  [pod_cidr_matches_intended]="control-plane"
  [default_storageclass]="storage"
  [storage_version_expected]="storage"
  [gatekeeper_ready]="gatekeeper"
  [gatekeeper_version_expected]="gatekeeper"
  [chainguard_constraint_deny]="gatekeeper"
  [authentik_healthy]="authentik"
  [cloudflared_healthy]="cloudflared"
  [cloudflared_tunnel_ready]="cloudflared"
)

# required .env key -> "consuming-stage:collection-mode" (generate | prompt | confirm)
declare -A DESIRED_INPUT=(
  [AUTHENTIK_SECRET_KEY]="authentik:generate"
  [AUTHENTIK_POSTGRES_PASSWORD]="authentik:generate"
  [CLOUDFLARE_TUNNEL_TOKEN]="cloudflared:prompt"
  [POD_CIDR]="control-plane:confirm"
)

# --- Cluster reachability (tri-state: met / unmet / unknown) -----------------
# A cluster-dependent scan can fail for two very different reasons:
#   unmet   - we reached the cluster and the resource genuinely is not there
#   unknown - we could not reach the cluster at all, so we cannot tell
# Reporting "unknown" as "unmet" is dangerous: it makes the pipeline try to
# rebuild a live cluster (e.g. 'kubeadm init' against a running API server).
# These helpers let preflight tell the two apart.

# kube_reachable — 0 when kubectl can actually talk to the API server as $USER.
kube_reachable() {
  command -v kubectl >/dev/null 2>&1 || return 1
  kubectl get --raw='/readyz' >/dev/null 2>&1 && return 0
  kubectl get nodes >/dev/null 2>&1
}

# control_plane_running — 0 when a control plane is live on this node, even if
# kubectl cannot reach it. Uses signals that do not require root:
#   - something is listening on the API server's secure port
#   - the static pod manifest exists (root-only path; try passwordless sudo)
control_plane_running() {
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':6443'; then
    return 0
  fi
  if sudo -n test -f /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null; then
    return 0
  fi
  return 1
}

# admin_conf_present — 0 when /etc/kubernetes/admin.conf exists. /etc/kubernetes
# is mode 700 root:root, so a plain [ -f ] is FALSE for non-root even when the
# file exists; fall back to passwordless sudo, then to a running control plane.
admin_conf_present() {
  [ -f /etc/kubernetes/admin.conf ] && return 0
  sudo -n test -f /etc/kubernetes/admin.conf 2>/dev/null && return 0
  return 1
}

# One scan_<check> per DESIRED_STAGE key: return 0 when the desired state is met.
# Cluster-dependent scans return 1 when unreachable; preflight_needed_stages
# gates on kube_reachable/control_plane_running first so an unreachable-but-live
# cluster is reported as UNKNOWN rather than silently treated as unmet.

scan_apt_based() { command -v apt-get >/dev/null 2>&1; }

scan_kernel_modules() {
  lsmod 2>/dev/null | grep -qw overlay \
    && lsmod 2>/dev/null | grep -qw br_netfilter
}

scan_sysctl_k8s() {
  [ "$(sysctl -n net.bridge.bridge-nf-call-iptables  2>/dev/null)" = "1" ] \
    && [ "$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)" = "1" ] \
    && [ "$(sysctl -n net.ipv4.ip_forward               2>/dev/null)" = "1" ]
}

scan_swap_off() {
  [ -z "$(swapon --noheadings --show 2>/dev/null)" ]
}

scan_containerd_systemd_cgroup() {
  systemctl is-active --quiet containerd 2>/dev/null \
    && grep -q 'SystemdCgroup = true' /etc/containerd/config.toml 2>/dev/null
}

# git is needed by the cloudflared stage to clone its chart. Without a desired
# state check, a prereqs stage already marked met/complete never installs it and
# the failure only surfaces much later, mid-pipeline.
scan_git_installed() { command -v git >/dev/null 2>&1; }

# The pod CIDR must not overlap the node's LAN subnet(s). If it does, pod->LAN
# traffic (router, DNS) is routed into the Calico overlay instead of NATed out,
# which silently breaks all external DNS from pods. Catch it before kubeadm init
# bakes the bad CIDR into the cluster.
scan_pod_cidr_no_lan_overlap() {
  local pod_cidr lan
  pod_cidr="$(intended_pod_cidr)"
  [ -n "${pod_cidr}" ] || return 0
  while IFS= read -r lan; do
    [ -n "${lan}" ] || continue
    if cidr_overlap "${pod_cidr}" "${lan}"; then
      warn "pod CIDR ${pod_cidr} overlaps node LAN ${lan}: pods could not reach the LAN/DNS."
      warn "set POD_CIDR to a non-overlapping range (e.g. 10.244.0.0/16) in .env."
      return 1
    fi
  done < <(node_lan_cidrs)
  return 0
}

scan_kube_tools_held() {
  command -v apt-mark >/dev/null 2>&1 || return 1
  local held pkg
  held="$(apt-mark showhold 2>/dev/null)" || return 1
  for pkg in kubelet kubeadm kubectl; do
    printf '%s\n' "${held}" | grep -qx "${pkg}" || return 1
  done
  return 0
}

# Initialized when admin.conf exists OR a control plane is already running.
# (A bare '[ -f /etc/kubernetes/admin.conf ]' is false for non-root because
# /etc/kubernetes is mode 700, which previously produced a false "unmet".)
scan_control_plane_initialized() {
  admin_conf_present && return 0
  control_plane_running
}

scan_kubeconfig_installed() {
  [ -f "${HOME}/.kube/config" ] || return 1
  command -v kubectl >/dev/null 2>&1 || return 1
  kubectl get nodes >/dev/null 2>&1
}

scan_cp_taint_removed() {
  command -v kubectl >/dev/null 2>&1 || return 1
  local taints
  taints="$(kubectl get nodes \
              -o jsonpath='{range .items[*]}{range .spec.taints[*]}{.key}{"\n"}{end}{end}' \
              2>/dev/null)" || return 1
  ! printf '%s\n' "${taints}" | grep -qx 'node-role.kubernetes.io/control-plane'
}

scan_calico_available() {
  command -v kubectl >/dev/null 2>&1 || return 1
  kubectl wait --for=condition=Available \
    deploy/calico-kube-controllers -n calico-system --timeout=1s >/dev/null 2>&1
}

# The live cluster's pod CIDR matches the one this pipeline intends (POD_CIDR in
# .env, else the default). The pod CIDR is fixed at kubeadm init and cannot be
# changed in place, so a mismatch means the running cluster was built with a
# different CIDR than .env now says. Surfacing it as unmet makes that drift
# visible instead of silently persisting (the exact trap: .env said 10.245 but
# the live cluster was 192.168). Reconciling requires a whip + rebuild.
scan_pod_cidr_matches_intended() {
  kube_reachable || return 1
  local want got
  want="$(intended_pod_cidr)"
  [ -n "${want}" ] || return 0
  # Use the node's podCIDR (cheap, authoritative) rather than 'cluster-info
  # dump' (large/slow; its grep|pipefail can spuriously fail). The node carries
  # a per-node slice (e.g. 10.245.0.0/24) of the cluster /16, so compare by
  # network containment, not exact string.
  got="$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null)" || return 1
  [ -n "${got}" ] || return 1
  if cidr_overlap "${want}" "${got}"; then
    return 0
  fi
  warn "live cluster pod CIDR (${got}) is not within intended POD_CIDR (${want}); the pod CIDR is"
  warn "fixed at init time. To adopt ${want}, whip the cluster and rebuild (editing .env alone cannot change it)."
  return 1
}

# The running cluster minor matches the minor this pipeline targets. Catches
# version drift that an existence-only check would report as "met".
scan_k8s_version_expected() {
  kube_reachable || return 1
  local want got
  want="$(resolve_k8s_minor)"
  got="$(discover_cluster_minor)"
  [ -n "${got}" ] || return 1
  [ "${got}" = "${want}" ]
}

# The deployed calico-node image tag matches the curated/overridden version for
# the running cluster minor.
scan_calico_version_expected() {
  kube_reachable || return 1
  local minor want got
  minor="$(discover_cluster_minor)"
  [ -n "${minor}" ] || return 1
  want="$(expected_calico_version "${minor}")" || return 1
  got="$(workload_image_tag calico-system daemonset calico-node)"
  [ -n "${got}" ] && [ "${got}" = "${want}" ]
}

# workload_image_tag NS KIND NAME — tag of the first container's image ("" if absent).
workload_image_tag() {
  local ns="$1" kind="$2" name="$3" image
  image="$(kubectl -n "${ns}" get "${kind}" "${name}" \
             -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" || true
  [ -n "${image}" ] || { echo ""; return 0; }
  image_tag "${image}"
}

scan_gatekeeper_version_expected() {
  kube_reachable || return 1
  [ "$(workload_image_tag gatekeeper-system deploy gatekeeper-controller-manager)" = "${KB_GATEKEEPER_VERSION}" ]
}

scan_storage_version_expected() {
  kube_reachable || return 1
  [ "$(workload_image_tag local-path-storage deploy local-path-provisioner)" = "${KB_LOCAL_PATH_PROVISIONER_VERSION}" ]
}

# helm_chart_version RELEASE NS — "chart-x.y.z" of a release ("" if absent).
helm_chart_version() {
  command -v helm >/dev/null 2>&1 || { echo ""; return 0; }
  helm list -n "$2" --filter "^$1\$" -o json 2>/dev/null \
    | grep -o '"chart":"[^"]*"' | head -n1 | cut -d'"' -f4 || true
}

# Human-readable inventory printed when everything is met.
report_versions() {
  local k8s
  k8s="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)" || true
  info "  kubernetes   ${k8s:-?}"
  info "  calico       $(workload_image_tag calico-system daemonset calico-node)"
  info "  local-path   $(workload_image_tag local-path-storage deploy local-path-provisioner)"
  info "  gatekeeper   $(workload_image_tag gatekeeper-system deploy gatekeeper-controller-manager)"
  info "  authentik    $(helm_chart_version authentik authentik)"
  info "  cloudflared  $(helm_chart_version cloudflared authentik)"
}

scan_default_storageclass() {
  command -v kubectl >/dev/null 2>&1 || return 1
  local count
  count="$(kubectl get sc \
             -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
             2>/dev/null \
             | grep -cx 'true')" || true
  [ "${count}" = "1" ]
}

scan_gatekeeper_ready() {
  command -v kubectl >/dev/null 2>&1 || return 1
  kubectl wait --for=condition=Available \
    deploy/gatekeeper-controller-manager -n gatekeeper-system --timeout=1s >/dev/null 2>&1
}

scan_chainguard_constraint_deny() {
  command -v kubectl >/dev/null 2>&1 || return 1
  local actions
  actions="$(kubectl get k8sallowedreposv2.constraints.gatekeeper.sh only-chainguard-images \
               -o jsonpath='{.spec.scopedEnforcementActions[*].action}' \
               2>/dev/null)" || return 1
  [ -n "${actions}" ] || return 1
  local action
  for action in ${actions}; do
    [ "${action}" = "deny" ] || return 1
  done
  return 0
}

scan_authentik_healthy() { helm_release_healthy authentik authentik; }

scan_cloudflared_healthy() { helm_release_healthy cloudflared authentik; }

# Beyond 'helm deployed': the tunnel connector must actually be registered with
# Cloudflare. Reported separately so a connected-but-unhealthy-helm state and a
# healthy-helm-but-disconnected-tunnel state are both visible.
scan_cloudflared_tunnel_ready() { cloudflared_tunnel_ready authentik; }

# Run every scanner; emit the set of stage names whose desired state is unmet.
# stdout is contract: ONLY stage names (bootstrap parses it). All human-readable
# output goes to stderr via info/warn/err.
preflight_needed_stages() {
  # Load .env so scanners that read persisted inputs (POD_CIDR via
  # intended_pod_cidr) see them. Without this, intended_pod_cidr falls back to
  # the default and the CIDR scanners compare against the wrong value.
  env_load

  # Tri-state guard. If a control plane is live but kubectl cannot reach it, we
  # are in UNKNOWN territory: every cluster scan would fail and we would wrongly
  # report a healthy deployment as entirely missing (and try to re-init it).
  # Fail loudly instead of emitting a destructive run list.
  if control_plane_running && ! kube_reachable; then
    err "a Kubernetes control plane IS running on this node, but kubectl cannot reach it."
    err "state is UNKNOWN, not missing - refusing to report stages as unmet."
    err ""
    err "most likely your kubeconfig is missing or unreadable. restore it with:"
    err "  mkdir -p \"\${HOME}/.kube\""
    err "  sudo cp /etc/kubernetes/admin.conf \"\${HOME}/.kube/config\""
    err "  sudo chown \"\$(id -u):\$(id -g)\" \"\${HOME}/.kube/config\""
    err "  chmod 600 \"\${HOME}/.kube/config\""
    err ""
    err "then re-run this command. (verify with: kubectl get nodes)"
    die "preflight cannot determine cluster state"
  fi

  local -A need=()
  local -a met_checks=() unmet_checks=()
  local check
  # Sort for stable, readable output.
  local -a checks=()
  while IFS= read -r check; do checks+=("${check}"); done \
    < <(printf '%s\n' "${!DESIRED_STAGE[@]}" | sort)

  for check in "${checks[@]}"; do
    if "scan_${check}" 2>/dev/null; then
      met_checks+=("${check}")
    else
      need["${DESIRED_STAGE[$check]}"]=1
      unmet_checks+=("${check}")
    fi
  done

  # Report met checks so a converged cluster is visibly verified, not silent.
  for check in "${met_checks[@]}"; do
    info "  [ok]    ${check}"
  done
  for check in "${unmet_checks[@]}"; do
    info "  [needs] ${check} -> stage '${DESIRED_STAGE[$check]}'"
  done

  local total="${#checks[@]}" ok="${#met_checks[@]}"
  if [ "${#need[@]}" -eq 0 ]; then
    info ""
    info "deployment is good: all ${total} desired-state checks met (including versions)"
    report_versions
    return 0
  fi

  info ""
  info "desired state: ${ok}/${total} checks met; ${#need[@]} stage(s) need reconciliation"
  printf '%s\n' "${!need[@]}"
}

# For each required input whose consuming stage is in the run list, collect it by
# mode. Keys already present in .env are skipped by the env_* helpers.
preflight_collect_inputs() {
  local -A running=()
  local s
  for s in "$@"; do running["${s}"]=1; done
  env_load
  local key stage mode
  for key in "${!DESIRED_INPUT[@]}"; do
    stage="${DESIRED_INPUT[$key]%%:*}"
    mode="${DESIRED_INPUT[$key]##*:}"
    [ -n "${running[${stage}]:-}" ] || continue
    case "${mode}" in
      generate) env_require_or_generate "${key}" ;;
      prompt)   env_require_or_prompt   "${key}" "Enter ${key}: " ;;
      confirm)  env_confirm_or_default  "${key}" "$(resolve_pod_cidr)" ;;
      *)        warn "unknown collection mode '${mode}' for input '${key}'" ;;
    esac
  done
}

usage() {
  cat >&2 <<'EOF'
Usage: preflight.sh --emit-needed
       preflight.sh --collect-inputs STAGES...

  --emit-needed            Print the stage names whose desired state is unmet.
  --collect-inputs STAGES  Collect required .env inputs for the given run list.
  -h, --help               Show this help.
EOF
}

main() {
  local cmd="${1:---emit-needed}"
  case "${cmd}" in
    --emit-needed)    preflight_needed_stages ;;
    --collect-inputs) shift; preflight_collect_inputs "$@" ;;
    -h|--help)        usage ;;
    *)                err "unknown argument: ${cmd}"; usage; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
