#!/usr/bin/env bash
#
# Stage 5 (gatekeeper): OPA Gatekeeper + Chainguard image allowlist. Migrated
# from gettingStarted.md §5-8. Applies the policy at dryrun, then flips to deny
# once the template is Established.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

stage_init "gatekeeper"

readonly GATEKEEPER_VERSION="${KB_GATEKEEPER_VERSION}"
readonly GATEKEEPER_MANIFEST="https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${GATEKEEPER_VERSION}/deploy/gatekeeper.yaml"

readonly GATEKEEPER_NS="gatekeeper-system"
readonly GATEKEEPER_CONTROLLER="gatekeeper-controller-manager"
readonly GATEKEEPER_AUDIT="gatekeeper-audit"

readonly TEMPLATE_FILE="${KB_ASSETS_DIR}/allowed-images-template.yaml"
readonly CONSTRAINT_FILE="${KB_ASSETS_DIR}/only-chainguard-images.yaml"
readonly TEMPLATE_NAME="k8sallowedreposv2"
readonly TEMPLATE_CRD="k8sallowedreposv2.constraints.gatekeeper.sh"
readonly CONSTRAINT_KIND="k8sallowedreposv2"
readonly CONSTRAINT_NAME="only-chainguard-images"

require_cluster

[ -f "${TEMPLATE_FILE}" ]   || die "ConstraintTemplate asset not found at ${TEMPLATE_FILE}"
[ -f "${CONSTRAINT_FILE}" ] || die "Chainguard allowlist asset not found at ${CONSTRAINT_FILE}"

# Install Gatekeeper and wait for both Deployments.
info "installing OPA Gatekeeper (${GATEKEEPER_VERSION})"
kapply -f "${GATEKEEPER_MANIFEST}"
wait_rollout "${GATEKEEPER_CONTROLLER}" "${GATEKEEPER_NS}" "180s"
wait_rollout "${GATEKEEPER_AUDIT}" "${GATEKEEPER_NS}" "180s"

# Template, then wait for its CRD before applying the constraint.
info "applying custom Deployment-aware ConstraintTemplate '${TEMPLATE_NAME}'"
kapply -f "${TEMPLATE_FILE}"
wait_crd_established "crd/${TEMPLATE_CRD}" "120s"

info "applying Chainguard allowlist constraint '${CONSTRAINT_NAME}' (authored at dryrun)"
kapply -f "${CONSTRAINT_FILE}"

# Flip scoped enforcement from dryrun to deny (idempotent JSON patch).
info "switching scoped enforcement action to 'deny'"
kubectl patch "${CONSTRAINT_KIND}" "${CONSTRAINT_NAME}" --type=json -p '[
  {
    "op": "replace",
    "path": "/spec/scopedEnforcementActions",
    "value": [
      {
        "action": "deny",
        "enforcementPoints": [
          {"name": "validation.gatekeeper.sh"},
          {"name": "audit.gatekeeper.sh"}
        ]
      }
    ]
  }
]'

# Verify: template compiled, CRD Established, action == deny.
info "verifying ConstraintTemplate '${TEMPLATE_NAME}' compiled without errors"
template_errors="$(kubectl get constrainttemplate "${TEMPLATE_NAME}" \
  -o jsonpath='{range .status.byPod[*]}{.errors}{"\n"}{end}' 2>/dev/null \
  | grep -v '^$' || true)"
if [ -n "${template_errors}" ]; then
  err "ConstraintTemplate '${TEMPLATE_NAME}' reported compile errors in status.byPod:"
  kubectl get constrainttemplate "${TEMPLATE_NAME}" -o yaml >&2 || true
  die "ConstraintTemplate '${TEMPLATE_NAME}' failed to compile"
fi

if ! kubectl get crd "${TEMPLATE_CRD}" \
  -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null \
  | grep -q "True"; then
  die "CRD ${TEMPLATE_CRD} is not Established"
fi

non_deny="$(kubectl get "${CONSTRAINT_KIND}" "${CONSTRAINT_NAME}" \
  -o jsonpath='{range .spec.scopedEnforcementActions[*]}{.action}{"\n"}{end}' 2>/dev/null \
  | grep -v '^deny$' || true)"
if [ -n "${non_deny}" ]; then
  err "constraint '${CONSTRAINT_NAME}' has non-deny scoped action(s):"
  kubectl get "${CONSTRAINT_KIND}" "${CONSTRAINT_NAME}" -o yaml >&2 || true
  die "constraint '${CONSTRAINT_NAME}' scoped enforcement action is not 'deny'"
fi

info "verified: template compiled, CRD Established, constraint action == deny"
info "stage 'gatekeeper' complete"
