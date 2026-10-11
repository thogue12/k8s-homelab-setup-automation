#!/usr/bin/env bash
#
# Stage 3 (calico): install the Calico CNI. Migrated from setup-calico-network.sh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

stage_init "calico"

require_cluster

# Resolve version + CIDR.
CLUSTER_MINOR="$(discover_cluster_minor)"
[ -n "${CLUSTER_MINOR}" ] || die "could not determine the Kubernetes server version via kubectl; is the API server up and \$HOME/.kube/config set?"
info "Kubernetes server version: ${CLUSTER_MINOR}"

CALICO_VERSION="$(resolve_calico_version "${CLUSTER_MINOR}")"
info "Calico version: ${CALICO_VERSION}"

POD_CIDR_RESOLVED="$(resolve_pod_cidr)"
if [ -n "${POD_CIDR_RESOLVED}" ]; then
  info "Pod CIDR: ${POD_CIDR_RESOLVED}"
else
  info "Pod CIDR: (not detected; using default 10.244.0.0/16)"
fi

BASE="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# CRDs + Tigera operator (server-side apply for the large CRDs).
# --force-conflicts: on re-runs the Tigera operator becomes the field manager
# for some of these objects (e.g. webhook .spec.mutations); re-asserting our
# known-good manifests must co-own those fields rather than fail the apply.
info "installing Calico CRDs and Tigera operator (${CALICO_VERSION})"
kapply --server-side --force-conflicts -f "${BASE}/v3_projectcalico_org.yaml"
kapply --server-side --force-conflicts -f "${BASE}/tigera-operator.yaml"

# Custom resources with the resolved CIDR injected into the cidr: field.
info "preparing Calico custom resources"
CR_FILE="${WORKDIR}/custom-resources.yaml"
require_cmd curl "needed to download the Calico custom-resources manifest"
curl -fsSL "${BASE}/custom-resources.yaml" -o "${CR_FILE}"

if [ -n "${POD_CIDR_RESOLVED}" ]; then
  if grep -qE '^[[:space:]]*cidr:' "${CR_FILE}"; then
    sed -i -E "s#(^[[:space:]]*cidr:[[:space:]]*).*#\1${POD_CIDR_RESOLVED}#" "${CR_FILE}"
    info "set Calico IP pool cidr to ${POD_CIDR_RESOLVED}"
  else
    warn "no 'cidr:' field found in custom-resources.yaml; applying as-is"
  fi
fi

kapply -f "${CR_FILE}"

# The operator reconciles the Installation CR asynchronously: tigerastatus
# objects, the calico-system namespace, and its workloads all appear *after*
# this apply returns. 'kubectl wait' fails immediately on objects that do not
# exist yet ("no matching resources found"), so poll instead: done when the
# core 'calico' tigerastatus exists and every tigerastatus reports Available.
readonly CALICO_TIMEOUT_S=600
info "waiting up to ${CALICO_TIMEOUT_S}s for the Tigera operator to reconcile (tigerastatus)"
deadline=$((SECONDS + CALICO_TIMEOUT_S))
while :; do
  statuses="$(kubectl get tigerastatus \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Available")].status}{"\n"}{end}' \
    2>/dev/null)" || statuses=""
  if printf '%s\n' "${statuses}" | grep -q '^calico=' \
     && ! printf '%s\n' "${statuses}" | grep -v '^$' | grep -qv '=True$'; then
    break
  fi
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    err "Tigera operator did not report all components Available within ${CALICO_TIMEOUT_S}s; current state:"
    printf '%s\n' "${statuses:-<no tigerastatus objects>}" | sed 's/^/  /' >&2
    err "inspect with:"
    err "  kubectl get tigerastatus"
    err "  kubectl -n calico-system get pods -o wide"
    err "  kubectl -n tigera-operator logs deploy/tigera-operator"
    die "Calico (Tigera) failed to reconcile to Available"
  fi
  sleep 5
done
info "all tigerastatus components Available"

# Belt and braces: the deployment preflight checks must exist before waiting on it.
until resource_exists deploy calico-kube-controllers calico-system; do
  [ "${SECONDS}" -lt "${deadline}" ] || die "deploy/calico-kube-controllers never appeared in calico-system"
  sleep 5
done
wait_available calico-kube-controllers calico-system 300s

info "Calico deployment complete"
