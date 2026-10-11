#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Discover the shell scripts to check (relative to SCRIPT_DIR) ------------
# bootstrap.sh, preflight.sh, lib/common.sh, every stages/*.sh, and this script.
SCRIPTS=(
  "${SCRIPT_DIR}/bootstrap.sh"
  "${SCRIPT_DIR}/preflight.sh"
  "${SCRIPT_DIR}/lib/common.sh"
)
# stages/*.sh — collected via a glob so newly added stages are picked up.
shopt -s nullglob
for stage in "${SCRIPT_DIR}"/stages/*.sh; do
  SCRIPTS+=("${stage}")
done
for t in "${SCRIPT_DIR}"/tests/*.sh; do
  SCRIPTS+=("${t}")
done
shopt -u nullglob
# Include this script itself.
SCRIPTS+=("${SCRIPT_DIR}/check.sh")

# --- Discover asset manifests ------------------------------------------------
ASSETS=()
shopt -s nullglob
for asset in "${SCRIPT_DIR}"/assets/*.yaml; do
  ASSETS+=("${asset}")
done
shopt -u nullglob

# --- Result accounting -------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
declare -a RESULTS=()

record() { # record STATUS "description"
  local status="$1" desc="$2"
  case "$status" in
    PASS) PASS=$((PASS + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
    SKIP) SKIP=$((SKIP + 1)) ;;
  esac
  RESULTS+=("${status}  ${desc}")
}

rel() { # path relative to SCRIPT_DIR for tidy output
  printf '%s' "${1#"${SCRIPT_DIR}/"}"
}

echo "== k8s-bootstrap static-analysis gate =="
echo "   base: ${SCRIPT_DIR}"
echo

# --- 1. bash -n on every script (MANDATORY) ----------------------------------
echo "-- bash -n (syntax check, mandatory) --"
for s in "${SCRIPTS[@]}"; do
  if [ ! -f "$s" ]; then
    record FAIL "bash -n $(rel "$s") (missing)"
    echo "  FAIL  $(rel "$s") — file not found"
    continue
  fi
  if bash -n "$s" 2>/tmp/kb_bashn_err; then
    record PASS "bash -n $(rel "$s")"
    echo "  PASS  $(rel "$s")"
  else
    record FAIL "bash -n $(rel "$s")"
    echo "  FAIL  $(rel "$s")"
    sed 's/^/        /' /tmp/kb_bashn_err || true
  fi
done
rm -f /tmp/kb_bashn_err
echo

# --- 2. shellcheck on every script (warnings = errors) -----------------------
echo "-- shellcheck (warnings treated as errors) --"
if command -v shellcheck >/dev/null 2>&1; then
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || { record FAIL "shellcheck $(rel "$s") (missing)"; continue; }
    if shellcheck --severity=warning --external-sources "$s"; then
      record PASS "shellcheck $(rel "$s")"
      echo "  PASS  $(rel "$s")"
    else
      record FAIL "shellcheck $(rel "$s")"
      echo "  FAIL  $(rel "$s")"
    fi
  done
else
  echo "  SKIP  shellcheck is not installed — skipping lint."
  echo "        Install it (e.g. 'brew install shellcheck' or 'apt-get install shellcheck')"
  echo "        to enable the lint gate. bash -n above is the mandatory gate."
  record SKIP "shellcheck (not installed)"
fi
echo

# --- 3. kubectl --dry-run=client validation of assets/*.yaml -----------------
echo "-- kubectl apply --dry-run=client (asset validation) --"
if [ "${#ASSETS[@]}" -eq 0 ]; then
  echo "  SKIP  no assets/*.yaml found."
  record SKIP "asset validation (no assets)"
elif ! command -v kubectl >/dev/null 2>&1; then
  echo "  SKIP  kubectl is not installed — skipping asset validation."
  record SKIP "asset validation (kubectl not installed)"
elif ! kubectl cluster-info >/dev/null 2>&1; then
  echo "  SKIP  no cluster reachable — skipping asset validation."
  echo "        These CRD-based manifests need the API server to recognise their"
  echo "        resource types; run this check against a live cluster to validate."
  record SKIP "asset validation (no cluster reachable)"
else
  for a in "${ASSETS[@]}"; do
    if kubectl apply --dry-run=client -f "$a" >/dev/null 2>/tmp/kb_kubectl_err; then
      record PASS "dry-run $(rel "$a")"
      echo "  PASS  $(rel "$a")"
    else
      record FAIL "dry-run $(rel "$a")"
      echo "  FAIL  $(rel "$a")"
      sed 's/^/        /' /tmp/kb_kubectl_err || true
    fi
  done
  rm -f /tmp/kb_kubectl_err
fi
echo

# --- 4. unit tests (tests/*.sh) — mandatory, no cluster needed ---------------
echo "-- unit tests (tests/*.sh) --"
shopt -s nullglob
UNIT_TESTS=("${SCRIPT_DIR}"/tests/*.sh)
shopt -u nullglob
if [ "${#UNIT_TESTS[@]}" -eq 0 ]; then
  echo "  SKIP  no tests/*.sh found."
  record SKIP "unit tests (none found)"
else
  for t in "${UNIT_TESTS[@]}"; do
    if bash "$t" >/tmp/kb_unit_out 2>&1; then
      record PASS "unit $(rel "$t")"
      echo "  PASS  $(rel "$t")"
    else
      record FAIL "unit $(rel "$t")"
      echo "  FAIL  $(rel "$t")"
      sed 's/^/        /' /tmp/kb_unit_out || true
    fi
  done
  rm -f /tmp/kb_unit_out
fi
echo

# --- Summary -----------------------------------------------------------------
echo "== summary =="
for line in "${RESULTS[@]}"; do
  echo "  ${line}"
done
echo
echo "  passed: ${PASS}  failed: ${FAIL}  skipped: ${SKIP}"

if [ "${FAIL}" -gt 0 ]; then
  echo
  echo "RESULT: FAIL — ${FAIL} mandatory check(s) failed."
  exit 1
fi

echo
echo "RESULT: PASS"
exit 0
