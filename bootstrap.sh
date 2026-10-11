#!/usr/bin/env bash
#
# bootstrap.sh — orchestrator. Runs preflight, decides which stages to run, and
# dispatches them in order.
#
#   ./bootstrap.sh                 run every unmet / not-complete stage, in order
#   ./bootstrap.sh --stage NAME    run only NAME (alias: --only NAME)
#   ./bootstrap.sh --from NAME     run NAME and every subsequent stage
#   ./bootstrap.sh -h | --help     usage + stage list

set -Eeuo pipefail

# shellcheck disable=SC2155
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

stage_init "bootstrap"

readonly PREFLIGHT="${SCRIPT_DIR}/preflight.sh"

# Fixed execution order; name -> stage file.
readonly STAGES=(prereqs control-plane calico storage gatekeeper authentik cloudflared)
declare -A STAGE_FILE=(
  [prereqs]="stages/10-prereqs.sh"
  [control-plane]="stages/20-control-plane.sh"
  [calico]="stages/30-calico.sh"
  [storage]="stages/40-storage.sh"
  [gatekeeper]="stages/50-gatekeeper.sh"
  [authentik]="stages/60-authentik.sh"
  [cloudflared]="stages/70-cloudflared.sh"
)

usage() {
  cat >&2 <<EOF
Usage: bootstrap.sh [--stage NAME | --only NAME | --from NAME | -h|--help]

  (no flags)        Run every stage whose desired state is unmet plus any stage
                    not recorded complete in the ledger, in order.
  --stage NAME      Run only NAME (flags win over the diff and the ledger).
  --only NAME       Alias of --stage.
  --from NAME       Run NAME and every subsequent stage in order.
  -h, --help        Show this help and the stage list.

Stages (in execution order):
EOF
  local name
  for name in "${STAGES[@]}"; do
    printf '  %-14s %s\n' "${name}" "${STAGE_FILE[$name]}" >&2
  done
}

is_valid_stage() {
  local name="${1:-}" s
  for s in "${STAGES[@]}"; do
    [ "${s}" = "${name}" ] && return 0
  done
  return 1
}

stage_index() {
  local name="${1:?stage_index requires a stage name}" i
  for i in "${!STAGES[@]}"; do
    [ "${STAGES[$i]}" = "${name}" ] && { printf '%s\n' "${i}"; return 0; }
  done
  return 1
}

reject_unknown_stage() {
  local name="${1:-}"
  err "unknown stage: '${name}'"
  err "valid stage names: ${STAGES[*]}"
  exit 2
}

# Run a stage in a subshell; mark it complete on success.
dispatch_stage() {
  local name="${1:?dispatch_stage requires a stage name}"
  local file="${SCRIPT_DIR}/${STAGE_FILE[$name]}"
  [ -f "${file}" ] || die "stage file not found for '${name}': ${file}"
  info "=== running stage '${name}' (${STAGE_FILE[$name]}) ==="
  ( bash "${file}" )
  ledger_mark "${name}"
  info "=== stage '${name}' complete ==="
}

MODE="auto"            # auto | only | from
TARGET=""

parse_args() {
  case "${1:-}" in
    "")
      MODE="auto"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --stage|--only)
      TARGET="${2:-}"
      [ -n "${TARGET}" ] || { err "${1} requires a stage name"; usage; exit 2; }
      is_valid_stage "${TARGET}" || reject_unknown_stage "${TARGET}"
      MODE="only"
      ;;
    --from)
      TARGET="${2:-}"
      [ -n "${TARGET}" ] || { err "--from requires a stage name"; usage; exit 2; }
      is_valid_stage "${TARGET}" || reject_unknown_stage "${TARGET}"
      MODE="from"
      ;;
    *)
      err "unknown argument: ${1}"
      usage
      exit 2
      ;;
  esac
}

# Print the ordered stage names to run. On a no-flags run the Preflight_Diff is
# authoritative (self-heals drift); the ledger only short-circuits met stages.
compute_run_list() {
  case "${MODE}" in
    only)
      printf '%s\n' "${TARGET}"
      ;;
    from)
      local start i
      start="$(stage_index "${TARGET}")"
      for i in "${!STAGES[@]}"; do
        if [ "${i}" -ge "${start}" ]; then
          printf '%s\n' "${STAGES[$i]}"
        fi
      done
      ;;
    auto)
      # Preflight is authoritative: a stage runs only when its desired state is
      # unmet. A met stage missing from the ledger (e.g. ledger deleted, or the
      # cluster was built by an earlier run) is backfilled instead of re-run.
      local name
      for name in "${STAGES[@]}"; do
        if [ -n "${PREFLIGHT_DIFF[${name}]:-}" ]; then
          printf '%s\n' "${name}"
        elif ! ledger_is_done "${name}"; then
          info "skip '${name}': desired state met (backfilling ledger)"
          ledger_mark "${name}"
        else
          info "skip '${name}': desired state met"
        fi
      done
      ;;
  esac
}

main() {
  parse_args "$@"

  # Gather the Preflight_Diff (stages whose desired state is unmet).
  # Capture first so a preflight failure (e.g. unreachable-but-live control
  # plane) aborts here instead of being swallowed by process substitution and
  # silently producing an empty/destructive run list.
  declare -gA PREFLIGHT_DIFF=()
  local line preflight_out=""
  info "running preflight to compute the desired-state diff"
  if ! preflight_out="$("${PREFLIGHT}" --emit-needed)"; then
    die "preflight failed; refusing to continue (see errors above)"
  fi
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    PREFLIGHT_DIFF["${line}"]=1
  done <<< "${preflight_out}"

  # Compute the ordered run list.
  # Not via process substitution: compute_run_list may write the ledger and must
  # fail loudly if that write fails.
  local -a run_list=()
  local run_list_out
  run_list_out="$(compute_run_list)"
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    run_list+=("${line}")
  done <<< "${run_list_out}"

  if [ "${#run_list[@]}" -eq 0 ]; then
    info ""
    info "=============================================="
    info " deployment is good - nothing to do"
    info " all desired-state checks met, including versions"
    info "=============================================="
    return 0
  fi

  info "run list: ${run_list[*]}"

  # Collect inputs for the run list up front so nothing prompts mid-dispatch.
  info "collecting required inputs for the run list"
  "${PREFLIGHT}" --collect-inputs "${run_list[@]}"

  local name
  for name in "${run_list[@]}"; do
    dispatch_stage "${name}"
  done

  info "bootstrap complete: ${run_list[*]}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
