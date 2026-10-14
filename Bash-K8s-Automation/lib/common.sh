#!/usr/bin/env bash
#
# lib/common.sh — shared library sourced by the orchestrator, preflight, and
# every stage. Sets no shell options of its own; callers set `set -Eeuo pipefail`.

# Guard against double-sourcing.
if [ -n "${KB_COMMON_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
KB_COMMON_SH_LOADED=1

# 077 so .env and the ledger are not world/group readable.
umask 077

# Location-independent paths, resolved once at source time.
# shellcheck disable=SC2155
readonly KB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly KB_ROOT_DIR="$(cd "${KB_LIB_DIR}/.." && pwd)"
readonly KB_STATE_DIR="${KB_ROOT_DIR}/state"
readonly KB_STAGES_DIR="${KB_ROOT_DIR}/stages"
readonly KB_ASSETS_DIR="${KB_ROOT_DIR}/assets"
readonly KB_ENV_FILE="${KB_ROOT_DIR}/.env"

export PATH="${PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Logging / tracing -------------------------------------------------------
STAGE="${STAGE:-bootstrap}"

log()  { printf '[%s] %s\n' "${STAGE}" "$*" >&2; }
info() { log "$@"; }
warn() { printf '[%s][warn] %s\n' "${STAGE}" "$*" >&2; }
err()  { printf '[%s][error] %s\n' "${STAGE}" "$*" >&2; }

# die MSG [code] — print an error and exit nonzero (default 1).
die() {
  local msg="$1" code="${2:-1}"
  err "$msg"
  exit "$code"
}

# ERR-trap handler: report stage, line, and failing command.
_on_err() {
  local line="${1:-?}" cmd="${2:-?}" code="$?"
  err "stage '${STAGE}' failed at line ${line} (exit ${code}): ${cmd}"
  exit "$code"
}

# stage_init NAME — set the stage name and install the ERR trap.
stage_init() {
  STAGE="${1:?stage_init requires a stage name}"
  trap '_on_err "$LINENO" "$BASH_COMMAND"' ERR
}

# --- Preflight helpers -------------------------------------------------------
# require_cmd CMD [HINT] — fail if a binary is missing.
require_cmd() {
  local cmd="${1:?require_cmd requires a command name}" hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ -n "$hint" ]; then
      die "required command not found: '${cmd}' (${hint})"
    fi
    die "required command not found: '${cmd}'"
  fi
}

require_apt() {
  require_cmd apt-get "an apt-based distribution is required"
}

# require_cluster — fail if no cluster is reachable via kubectl.
require_cluster() {
  require_cmd kubectl "install kubectl and configure \$HOME/.kube/config"
  if ! kubectl cluster-info >/dev/null 2>&1; then
    die "no Kubernetes cluster reachable via kubectl (check \$HOME/.kube/config and that the API server is up)"
  fi
}

# --- Version / CIDR discovery (from lib-k8s-discovery.sh) ---------------------
# Curated Calico release per K8s minor; unknown -> return 1 so callers fail loud.
# Last reviewed: 2026-10.
calico_version_for_k8s() {
  local minor="$1"
  case "$minor" in
    1.31) echo "v3.30.0" ;;
    1.32) echo "v3.31.0" ;;
    1.33) echo "v3.31.0" ;;
    1.34) echo "v3.32.1" ;;
    1.35) echo "v3.33.0" ;;
    1.36) echo "v3.33.0" ;;
    1.37) echo "v3.33.0" ;;
    *)    return 1 ;;
  esac
}

# Running cluster server minor as "MAJOR.MINOR"; empty if no cluster reachable.
discover_cluster_minor() {
  command -v kubectl >/dev/null 2>&1 || { echo ""; return 0; }
  local json full
  json="$(kubectl version -o json 2>/dev/null)" || { echo ""; return 0; }
  full="$(printf '%s' "$json" \
            | tr -d '\n' \
            | grep -o '"serverVersion":[^}]*}' \
            | grep -o '"gitVersion": *"v[0-9]*\.[0-9]*\.[0-9]*"' \
            | head -n1 \
            | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*')" || true
  [ -z "$full" ] && { echo ""; return 0; }
  echo "${full#v}" | cut -d. -f1,2
}

# Installed kubeadm minor (e.g. 1.33); empty if not installed.
discover_installed_kubeadm_minor() {
  command -v kubeadm >/dev/null 2>&1 || { echo ""; return 0; }
  local full
  full="$(kubeadm version -o short 2>/dev/null)" || true
  [ -z "$full" ] && { echo ""; return 0; }
  echo "${full#v}" | cut -d. -f1,2
}

# Pod CIDR from kubeadm-config, else kube-controller-manager flag; empty if unknown.
discover_pod_cidr() {
  command -v kubectl >/dev/null 2>&1 || { echo ""; return 0; }
  local cidr=""
  cidr="$(kubectl -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null \
            | grep -oE 'podSubnet:[[:space:]]*[0-9./,]+' \
            | head -n1 \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')" || true
  if [ -n "$cidr" ]; then echo "$cidr"; return 0; fi
  cidr="$(kubectl -n kube-system get pod -l component=kube-controller-manager \
            -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null \
            | grep -oE 'cluster-cidr=[0-9./,]+' \
            | head -n1 \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+')" || true
  echo "$cidr"
}

# --- Version resolution (override precedence) --------------------------------
# Newest minor with a Calico table entry; the default when nothing else is known.
readonly LATEST_REVIEWED_MINOR="1.37"

# Pinned component versions. Single source of truth for the stages that install
# them and for preflight's version-drift checks.
readonly KB_GATEKEEPER_VERSION="v3.23.1"
readonly KB_LOCAL_PATH_PROVISIONER_VERSION="v0.0.37"
# The Gatekeeper allowlist (assets/only-chainguard-images.yaml) lists these
# images by exact tag. Changing a pin here without updating it there makes the
# install fail admission.
readonly KB_AUTHENTIK_CHART_VERSION="2026.8.3"   # deploys ghcr.io/goauthentik/server:2026.8.3
readonly KB_CLOUDFLARED_IMAGE_TAG="2026.10.0"    # chart default is :latest, which can't be pinned

# expected_calico_version MINOR — CALICO_VERSION override, else table; return 1
# (no die) when neither is known. Non-fatal sibling of resolve_calico_version.
expected_calico_version() {
  local minor="${1:?expected_calico_version requires a Kubernetes minor version}"
  if [ -n "${CALICO_VERSION:-}" ]; then
    echo "${CALICO_VERSION}"
    return 0
  fi
  calico_version_for_k8s "${minor}"
}

# image_tag IMAGE — print the tag of an image reference ("" if untagged).
image_tag() {
  local ref="${1%@*}"       # drop any @sha256 digest
  local last="${ref##*/}"   # tag lives in the final path segment
  case "${last}" in
    *:*) echo "${last##*:}" ;;
    *)   echo "" ;;
  esac
}

# K8S_MINOR override (leading "v" tolerated) -> else LATEST_REVIEWED_MINOR.
resolve_k8s_minor() {
  if [ -n "${K8S_MINOR:-}" ]; then
    local minor="${K8S_MINOR#v}"
    echo "${minor}" | cut -d. -f1,2
    return 0
  fi
  echo "${LATEST_REVIEWED_MINOR}"
}

# CALICO_VERSION override -> else table lookup; die if neither.
resolve_calico_version() {
  local minor="${1:?resolve_calico_version requires a Kubernetes minor version}"
  if [ -n "${CALICO_VERSION:-}" ]; then
    echo "${CALICO_VERSION}"
    return 0
  fi
  local version
  if ! version="$(calico_version_for_k8s "${minor}")"; then
    die "no curated Calico version for Kubernetes minor '${minor}'; update the compatibility table in lib/common.sh or set CALICO_VERSION"
  fi
  echo "${version}"
}

# POD_CIDR override -> else discovery (may be empty before kubeadm init).
resolve_pod_cidr() {
  if [ -n "${POD_CIDR:-}" ]; then
    echo "${POD_CIDR}"
    return 0
  fi
  discover_pod_cidr
}

# The pod CIDR the pipeline would use before kubeadm init: override, else the
# default this pipeline inits with (NOT Calico's 192.168.0.0/16 upstream default).
intended_pod_cidr() {
  if [ -n "${POD_CIDR:-}" ]; then
    echo "${POD_CIDR}"
  else
    echo "10.244.0.0/16"
  fi
}

# --- CIDR overlap detection --------------------------------------------------
# Pure-bash IPv4 helpers so the preflight guard needs no extra tooling.

# ip_to_int A.B.C.D -> 32-bit integer (no validation; caller supplies clean IPv4).
_ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# cidr_overlap CIDR_A CIDR_B — 0 (true) when the two IPv4 CIDRs intersect.
# Two ranges overlap iff each network base falls within the other's mask span.
cidr_overlap() {
  local a="$1" b="$2"
  local a_ip="${a%/*}" a_bits="${a#*/}"
  local b_ip="${b%/*}" b_bits="${b#*/}"
  # Non-IPv4 (e.g. IPv6) can't overlap an IPv4 range here; treat as no overlap.
  case "${a_ip}${b_ip}" in *:*) return 1 ;; esac
  local a_int b_int a_mask b_mask
  a_int="$(_ip_to_int "${a_ip}")"; b_int="$(_ip_to_int "${b_ip}")"
  a_mask=$(( a_bits == 0 ? 0 : (0xFFFFFFFF << (32 - a_bits)) & 0xFFFFFFFF ))
  b_mask=$(( b_bits == 0 ? 0 : (0xFFFFFFFF << (32 - b_bits)) & 0xFFFFFFFF ))
  # Compare on the wider (smaller prefix) of the two masks.
  local mask=$(( a_mask < b_mask ? a_mask : b_mask ))
  [ $(( a_int & mask )) -eq $(( b_int & mask )) ]
}

# node_lan_cidrs — the node's real LAN IPv4 interface CIDRs, one per line.
# Excludes interfaces that are NOT the LAN and would cause false overlap hits:
#   - loopback / link-local (169.254)
#   - docker0 (172.17)
#   - CNI/overlay interfaces (cali*, vxlan.calico, tunl*, flannel*, cni*), whose
#     addresses are carved FROM the pod CIDR — comparing the pod CIDR against its
#     own overlay interface always "overlaps" and is meaningless.
node_lan_cidrs() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -o -4 addr show scope global 2>/dev/null \
    | grep -vE '[[:space:]](cali[^[:space:]]*|vxlan\.calico|tunl[0-9]*|flannel[^[:space:]]*|cni[0-9]*)[[:space:]]' \
    | awk '{print $4}' \
    | grep -vE '^(169\.254\.|172\.17\.)' || true
}

# --- Idempotency helpers -----------------------------------------------------
# kubectl apply wrapper (never create) so applies converge on re-run.
kapply() {
  kubectl apply "$@"
}

# resource_exists KIND NAME [NS] — true if the object exists (skip-if-present).
resource_exists() {
  local kind="${1:?resource_exists requires a KIND}" \
        name="${2:?resource_exists requires a NAME}" \
        ns="${3:-}"
  if [ -n "$ns" ]; then
    kubectl get "$kind" "$name" -n "$ns" >/dev/null 2>&1
  else
    kubectl get "$kind" "$name" >/dev/null 2>&1
  fi
}

# wait_rollout DEPLOY NS TIMEOUT — block on rollout; print diagnostics and die on timeout.
wait_rollout() {
  local deploy="${1:?wait_rollout requires a deployment name}" \
        ns="${2:?wait_rollout requires a namespace}" \
        timeout="${3:?wait_rollout requires a timeout (e.g. 300s)}"
  info "waiting for rollout of deploy/${deploy} in ${ns} (timeout ${timeout})"
  if ! kubectl rollout status "deploy/${deploy}" -n "${ns}" --timeout="${timeout}"; then
    err "deploy/${deploy} in ${ns} did not finish rolling out within ${timeout}; inspect with:"
    err "  kubectl -n ${ns} rollout status deploy/${deploy}"
    err "  kubectl -n ${ns} get pods -l app.kubernetes.io/instance=${deploy} -o wide"
    err "  kubectl -n ${ns} describe deploy/${deploy}"
    err "  kubectl -n ${ns} get events --sort-by=.lastTimestamp"
    die "rollout of deploy/${deploy} in ${ns} timed out"
  fi
}

# wait_available DEPLOY NS TIMEOUT — block on Available; print diagnostics and die on timeout.
wait_available() {
  local deploy="${1:?wait_available requires a deployment name}" \
        ns="${2:?wait_available requires a namespace}" \
        timeout="${3:?wait_available requires a timeout (e.g. 300s)}"
  info "waiting for deploy/${deploy} in ${ns} to become Available (timeout ${timeout})"
  if ! kubectl wait --for=condition=Available "deploy/${deploy}" -n "${ns}" --timeout="${timeout}"; then
    err "deploy/${deploy} in ${ns} did not become Available within ${timeout}; inspect with:"
    err "  kubectl get tigerastatus"
    err "  kubectl -n ${ns} get pods -o wide"
    err "  kubectl -n ${ns} describe deploy/${deploy}"
    err "  kubectl -n ${ns} get events --sort-by=.lastTimestamp"
    die "deploy/${deploy} in ${ns} did not become Available within ${timeout}"
  fi
}

# wait_crd_established CRD TIMEOUT — block until a CRD is Established.
wait_crd_established() {
  local crd="${1:?wait_crd_established requires a CRD name}" \
        timeout="${2:?wait_crd_established requires a timeout (e.g. 120s)}"
  local ref="${crd#crd/}"
  info "waiting for CRD ${ref} to reach Established (timeout ${timeout})"
  if ! kubectl wait --for=condition=Established "crd/${ref}" --timeout="${timeout}"; then
    err "CRD ${ref} did not reach the Established condition within ${timeout}; inspect with:"
    err "  kubectl get crd ${ref} -o yaml"
    die "CRD ${ref} not Established within ${timeout}"
  fi
}

# helm_release_healthy NAME NS — true when helm status is `deployed` and its
# managed Deployments are ready. Used as the skip-if-healthy gate.
helm_release_healthy() {
  local name="${1:?helm_release_healthy requires a release name}" \
        ns="${2:?helm_release_healthy requires a namespace}"
  command -v helm >/dev/null 2>&1 || return 1

  local status
  status="$(helm status "${name}" -n "${ns}" -o json 2>/dev/null \
              | grep -o '"status":[[:space:]]*"[^"]*"' \
              | head -n1 \
              | grep -o '"[^"]*"$' \
              | tr -d '"')" || true
  [ "${status}" = "deployed" ] || return 1

  local unready
  unready="$(kubectl get deploy -n "${ns}" \
               -l "app.kubernetes.io/instance=${name}" \
               -o jsonpath='{range .items[*]}{.metadata.name}={.status.availableReplicas}/{.spec.replicas}{"\n"}{end}' \
               2>/dev/null \
               | awk -F'[=/]' 'NF==3 && $2!=$3 {print; found=1} END {exit (found?0:1)}')" || true
  if [ -n "${unready}" ]; then
    return 1
  fi
  return 0
}

# ensure_helm — install Helm 3 if missing, then require it.
ensure_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    info "helm not found; installing Helm"
    require_cmd curl "needed to fetch the Helm installer"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  require_cmd helm "install Helm 3 (https://helm.sh/docs/intro/install/)"
}

# cloudflared_tunnel_ready NS — 0 when at least one cloudflared pod's tunnel
# connector is registered with Cloudflare's edge.
#
# The connector exposes /ready on its metrics port (2000), which returns 200
# ONLY once the tunnel is connected. The chart wires that endpoint as the
# container's livenessProbe, so Kubernetes itself probes it from the kubelet
# (the distroless cloudflared image has no shell/wget/curl, so we cannot exec a
# probe ourselves). A connector with an invalid token or no DNS fails /ready,
# the liveness probe fails, and the container never reports ready=true while
# staying up — it crash-loops instead. So "a pod whose cloudflared container is
# ready=true and not restarting" is an accurate proxy for a live tunnel, checked
# entirely via the API server with no in-pod tooling.
cloudflared_tunnel_ready() {
  local ns="${1:?cloudflared_tunnel_ready requires a namespace}"
  command -v kubectl >/dev/null 2>&1 || return 1
  # ready status of each cloudflared container, one per pod.
  local readies
  readies="$(kubectl -n "${ns}" get pods -l pod=cloudflared \
               -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
               2>/dev/null)" || return 1
  # At least one container reports ready=true (its liveness /ready is passing).
  printf '%s\n' "${readies}" | grep -qx 'true'
}

# ensure_namespace NS — create NS if absent (idempotent apply).
ensure_namespace() {
  local ns="${1:?ensure_namespace requires a namespace}"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kapply -f -
}

# verify_release_deployed NAME NS — die unless helm reports the release `deployed`.
verify_release_deployed() {
  local name="${1:?verify_release_deployed requires a release name}" \
        ns="${2:?verify_release_deployed requires a namespace}"
  local status
  status="$(helm status "${name}" -n "${ns}" -o json 2>/dev/null \
              | grep -o '"status":[[:space:]]*"[^"]*"' \
              | head -n1 \
              | grep -o '"[^"]*"$' \
              | tr -d '"')" || true
  if [ "${status}" != "deployed" ]; then
    err "helm release '${name}' in '${ns}' is not 'deployed' (status: '${status:-<none>}'); inspect with:"
    err "  helm status ${name} -n ${ns}"
    err "  kubectl -n ${ns} get pods"
    die "helm release '${name}' not deployed"
  fi
  info "verified helm release '${name}' reports 'deployed'"
}

# helm_upgrade_install NAME CHART [ARGS...] — enforce `helm upgrade --install`.
helm_upgrade_install() {
  local name="${1:?helm_upgrade_install requires a release name}" \
        chart="${2:?helm_upgrade_install requires a chart reference}"
  shift 2
  helm upgrade --install "${name}" "${chart}" "$@"
}

# --- Secret management (.env) ------------------------------------------------
# Helpers write .env under umask 077 at mode 0600. Values are KEY='value' lines.

# env_load — source .env if present and export its values.
env_load() {
  umask 077
  [ -f "${KB_ENV_FILE}" ] || return 0
  chmod 600 "${KB_ENV_FILE}" 2>/dev/null || true
  set -a
  # shellcheck disable=SC1090
  . "${KB_ENV_FILE}"
  set +a
}

# env_persist KEY VALUE — append or replace KEY='value' atomically.
env_persist() {
  local key="${1:?env_persist requires a KEY}" value="${2-}"
  umask 077

  # Escape single quotes for single-quoted shell storage ( ' -> '\'' ).
  local sq="'" bs='\'
  local repl="${sq}${bs}${sq}${sq}"
  local escaped="${value//${sq}/${repl}}"
  local line="${key}=${sq}${escaped}${sq}"

  local dir tmp
  dir="$(dirname "${KB_ENV_FILE}")"
  mkdir -p "${dir}"
  tmp="$(mktemp "${dir}/.env.XXXXXX")"
  chmod 600 "${tmp}"

  if [ -f "${KB_ENV_FILE}" ]; then
    grep -v -E "^[[:space:]]*${key}=" "${KB_ENV_FILE}" > "${tmp}" 2>/dev/null || true
  fi
  printf '%s\n' "${line}" >> "${tmp}"

  mv -f "${tmp}" "${KB_ENV_FILE}"
  chmod 600 "${KB_ENV_FILE}"
}

# env_require_or_generate KEY — reuse if present, else generate and persist.
env_require_or_generate() {
  local key="${1:?env_require_or_generate requires a KEY}"
  if [ -n "${!key:-}" ]; then
    return 0
  fi
  require_cmd openssl "needed to generate the ${key} secret"
  local value
  value="$(openssl rand -hex 32)"
  printf -v "${key}" '%s' "${value}"
  export "${key?}"
  env_persist "${key}" "${value}"
  info "generated and persisted ${key}"
}

# env_require_or_prompt KEY PROMPT — reuse if present, else prompt and persist.
env_require_or_prompt() {
  local key="${1:?env_require_or_prompt requires a KEY}" \
        prompt="${2:-Enter ${1}: }"
  if [ -n "${!key:-}" ]; then
    return 0
  fi
  local value=""
  read -rsp "${prompt}" value </dev/tty
  printf '\n' >&2
  if [ -z "${value}" ]; then
    die "no value entered for ${key}; it is required"
  fi
  printf -v "${key}" '%s' "${value}"
  export "${key?}"
  env_persist "${key}" "${value}"
  info "persisted ${key}"
}

# env_confirm_or_default KEY DEFAULT — reuse if present, else confirm/override.
env_confirm_or_default() {
  local key="${1:?env_confirm_or_default requires a KEY}" \
        default="${2-}"
  if [ -n "${!key:-}" ]; then
    return 0
  fi
  local reply=""
  read -rp "${key} [${default}]: " reply </dev/tty
  local value="${reply:-${default}}"
  printf -v "${key}" '%s' "${value}"
  export "${key?}"
  env_persist "${key}" "${value}"
  info "persisted ${key}=${value}"
}

# --- Resume ledger -----------------------------------------------------------
# Newline-delimited file of completed stage names at state/.bootstrap-state.
readonly KB_LEDGER_FILE="${KB_STATE_DIR}/.bootstrap-state"

# ledger_is_done NAME — true when NAME is recorded (exact line match).
ledger_is_done() {
  local name="${1:?ledger_is_done requires a stage name}"
  [ -f "${KB_LEDGER_FILE}" ] || return 1
  grep -qxF "${name}" "${KB_LEDGER_FILE}"
}

# ledger_mark NAME — record NAME once (idempotent; file is 0644 so it's readable).
ledger_mark() {
  local name="${1:?ledger_mark requires a stage name}"
  if ledger_is_done "${name}"; then
    return 0
  fi
  umask 022
  mkdir -p "${KB_STATE_DIR}"
  printf '%s\n' "${name}" >> "${KB_LEDGER_FILE}"
  info "ledger: marked '${name}' complete"
}

# ledger_reset — remove the ledger so every stage is treated as not-done.
ledger_reset() {
  rm -f "${KB_LEDGER_FILE}"
  info "ledger: reset (${KB_LEDGER_FILE} removed)"
}
