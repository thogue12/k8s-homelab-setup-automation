#!/usr/bin/env bash
#
# Stage 7 (cloudflared): Cloudflare tunnel via the cloudflared Helm chart from a
# fork of damienjburks/homelab-helm-charts (MIT). The tunnel token lives only in a
# k8s Secret. Skips the install when the release is already healthy.
# Independent of Authentik: it creates the shared namespace itself if needed.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

stage_init "cloudflared"

readonly APPS_NS="authentik"
readonly CLOUDFLARED_RELEASE="cloudflared"
# Your fork of damienjburks/homelab-helm-charts (MIT, (c) 2025 Damien Burks).
# CLOUDFLARED_REPO_REF pins the clone to a branch/tag/commit for reproducible
# builds; override via env if you move the chart to a tag.
readonly CLOUDFLARED_REPO_URL="https://github.com/thogue12/homelab-helm-charts.git"
readonly CLOUDFLARED_REPO_REF="${CLOUDFLARED_REPO_REF:-main}"
# Anchored to the project root so the clone location doesn't depend on $PWD.
readonly CLOUDFLARED_REPO_DIR="${KB_ROOT_DIR}/homelab-helm-charts"
readonly CLOUDFLARED_CHART="${CLOUDFLARED_REPO_DIR}/cloudflared"
readonly TUNNEL_SECRET_NAME="cloudflare-tunnel-token"

require_cluster

# Standalone fallback: under the orchestrator preflight already collected these.
env_load

ensure_helm

if helm_release_healthy "${CLOUDFLARED_RELEASE}" "${APPS_NS}"; then
  info "cloudflared release already healthy in '${APPS_NS}'; skipping tunnel Secret and install"
else
  env_require_or_prompt CLOUDFLARE_TUNNEL_TOKEN "Enter CLOUDFLARE_TUNNEL_TOKEN (Cloudflare tunnel token, starts with eyJ): "

  ensure_namespace "${APPS_NS}"

  info "creating/updating Secret '${TUNNEL_SECRET_NAME}' in '${APPS_NS}' (token only in a k8s Secret)"
  kubectl create secret generic "${TUNNEL_SECRET_NAME}" \
    -n "${APPS_NS}" \
    --from-literal=token="${CLOUDFLARE_TUNNEL_TOKEN}" \
    --dry-run=client -o yaml | kapply -f -

  if [ ! -d "${CLOUDFLARED_CHART}" ]; then
    info "cloudflared chart not found at ${CLOUDFLARED_CHART}; cloning ${CLOUDFLARED_REPO_URL} @ ${CLOUDFLARED_REPO_REF}"
    require_cmd git "needed to clone the cloudflared Helm chart fork"
    git clone --depth 1 --branch "${CLOUDFLARED_REPO_REF}" \
      "${CLOUDFLARED_REPO_URL}" "${CLOUDFLARED_REPO_DIR}"
  fi

  info "installing cloudflared via helm upgrade --install (${CLOUDFLARED_CHART})"
  helm_upgrade_install "${CLOUDFLARED_RELEASE}" "${CLOUDFLARED_CHART}" \
    -n "${APPS_NS}" \
    --set image.tag="${KB_CLOUDFLARED_IMAGE_TAG}" \
    --wait
fi

verify_release_deployed "${CLOUDFLARED_RELEASE}" "${APPS_NS}"

# 'deployed' only means Helm applied the chart; it does NOT mean the tunnel
# connected. The chart's livenessProbe hits cloudflared's /ready (port 2000),
# which only passes once the connector registers with Cloudflare's edge. Wait
# for the container to report ready, so an invalid token or DNS failure fails
# this stage here instead of surfacing later as a crash loop.
info "verifying the cloudflared tunnel connector is registered (container ready)"
readonly TUNNEL_READY_TIMEOUT_S=120
tunnel_deadline=$((SECONDS + TUNNEL_READY_TIMEOUT_S))
until cloudflared_tunnel_ready "${APPS_NS}"; do
  if [ "${SECONDS}" -ge "${tunnel_deadline}" ]; then
    err "cloudflared tunnel did not become ready within ${TUNNEL_READY_TIMEOUT_S}s; inspect with:"
    err "  kubectl -n ${APPS_NS} get pods -l pod=cloudflared"
    err "  kubectl -n ${APPS_NS} logs -l pod=cloudflared --tail=30"
    err "  (common causes: invalid CLOUDFLARE_TUNNEL_TOKEN, or pods cannot resolve/reach *.argotunnel.com)"
    die "cloudflared tunnel connector not registered"
  fi
  sleep 5
done
info "cloudflared tunnel connector is registered and ready"

info "stage 'cloudflared' complete"
