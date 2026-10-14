#!/usr/bin/env bash
#
# Unit tests for the IPv4 CIDR-overlap helpers in lib/common.sh
# (_ip_to_int, cidr_overlap, intended_pod_cidr). Pure bash, no cluster needed.
#
#   ./tests/test-cidr-overlap.sh      # runs all cases; exits non-zero on failure

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# stage_init installs an ERR trap in common.sh; keep STAGE quiet for test output.
STAGE="test"
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

PASS=0
FAIL=0

# assert_overlap EXPECTED A B — EXPECTED is "yes" (overlap) or "no" (disjoint).
assert_overlap() {
  local expected="$1" a="$2" b="$3" got
  if cidr_overlap "${a}" "${b}"; then got="yes"; else got="no"; fi
  if [ "${got}" = "${expected}" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  overlap(%s, %s) = %s\n' "${a}" "${b}" "${got}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  overlap(%s, %s): expected %s, got %s\n' "${a}" "${b}" "${expected}" "${got}"
  fi
}

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s = %s\n' "${label}" "${actual}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s: expected %s, got %s\n' "${label}" "${expected}" "${actual}"
  fi
}

echo "== _ip_to_int =="
assert_eq "_ip_to_int 0.0.0.0"         "0"          "$(_ip_to_int 0.0.0.0)"
assert_eq "_ip_to_int 0.0.0.1"         "1"          "$(_ip_to_int 0.0.0.1)"
assert_eq "_ip_to_int 0.0.1.0"         "256"        "$(_ip_to_int 0.0.1.0)"
assert_eq "_ip_to_int 10.244.0.0"      "183762944"  "$(_ip_to_int 10.244.0.0)"
assert_eq "_ip_to_int 255.255.255.255" "4294967295" "$(_ip_to_int 255.255.255.255)"

echo "== cidr_overlap: the real bug (pod CIDR vs 192.168 LAN) =="
# Calico default swallows a 192.168.1.x home LAN -> MUST report overlap.
assert_overlap yes "192.168.0.0/16" "192.168.1.230/24"
assert_overlap yes "192.168.0.0/16" "192.168.1.0/24"
# The fix: 10.244/16 and 10.245/16 do NOT overlap a 192.168 LAN.
assert_overlap no  "10.244.0.0/16"  "192.168.1.230/24"
assert_overlap no  "10.245.0.0/16"  "192.168.1.230/24"

echo "== cidr_overlap: cluster-vs-cluster uniqueness =="
# Two clusters on the same range overlap (the connect-them-later problem).
assert_overlap yes "10.244.0.0/16"  "10.244.0.0/24"
# Distinct /16s do not.
assert_overlap no  "10.244.0.0/16"  "10.245.0.0/16"

echo "== cidr_overlap: containment and boundaries =="
assert_overlap yes "10.0.0.0/8"     "10.244.0.0/16"   # /16 inside /8
assert_overlap yes "10.244.0.0/16"  "10.0.0.0/8"      # order-independent
assert_overlap yes "10.244.5.0/24"  "10.244.5.0/24"   # identical
assert_overlap no  "10.244.0.0/16"  "10.245.0.0/16"   # adjacent, non-overlapping
assert_overlap no  "0.0.0.0/1"      "128.0.0.0/1"     # the two halves of /1
assert_overlap yes "0.0.0.0/0"      "10.244.0.0/16"   # /0 matches everything

echo "== cidr_overlap: IPv6 is ignored (treated as non-overlapping) =="
assert_overlap no  "10.244.0.0/16"  "2600:6c60::1/64"

echo "== intended_pod_cidr =="
assert_eq "intended_pod_cidr (POD_CIDR set)" "10.245.0.0/16" \
  "$(POD_CIDR=10.245.0.0/16 intended_pod_cidr)"
assert_eq "intended_pod_cidr (unset -> default)" "10.244.0.0/16" \
  "$(unset POD_CIDR; intended_pod_cidr)"

echo
echo "== summary =="
printf '  passed: %s  failed: %s\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
