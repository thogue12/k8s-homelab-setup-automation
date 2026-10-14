#!/usr/bin/env bash
#
# Stage 6 (authentik): Authentik via the goauthentik Helm chart. Split out of
# the former apps stage. Secrets come from .env and are never regenerated once
# set. Skips the install when the release is already healthy.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

stage_init "authentik"

readonly APPS_NS="authentik"
readonly AUTHENTIK_RELEASE="authentik"
readonly AUTHENTIK_REPO_NAME="authentik"
readonly AUTHENTIK_REPO_URL="https://charts.goauthentik.io"
readonly AUTHENTIK_CHART="authentik/authentik"

require_cluster

# Standalone fallback: under the orchestrator preflight already collected these.
env_load

ensure_helm

if helm_release_healthy "${AUTHENTIK_RELEASE}" "${APPS_NS}"; then
  info "Authentik release already healthy in '${APPS_NS}'; skipping install and NOT regenerating secrets"
else
  env_require_or_generate AUTHENTIK_SECRET_KEY
  env_require_or_generate AUTHENTIK_POSTGRES_PASSWORD

  info "adding goauthentik Helm repo '${AUTHENTIK_REPO_NAME}' (${AUTHENTIK_REPO_URL})"
  helm repo add "${AUTHENTIK_REPO_NAME}" "${AUTHENTIK_REPO_URL}" --force-update
  helm repo update "${AUTHENTIK_REPO_NAME}"

  info "installing Authentik via helm upgrade --install (${AUTHENTIK_CHART})"
  helm_upgrade_install "${AUTHENTIK_RELEASE}" "${AUTHENTIK_CHART}" \
    --version "${KB_AUTHENTIK_CHART_VERSION}" \
    -n "${APPS_NS}" --create-namespace \
    --set authentik.secret_key="${AUTHENTIK_SECRET_KEY}" \
    --set authentik.postgresql.password="${AUTHENTIK_POSTGRES_PASSWORD}" \
    --set postgresql.enabled=true \
    --set postgresql.auth.password="${AUTHENTIK_POSTGRES_PASSWORD}" \
    --wait --timeout 15m
fi

verify_release_deployed "${AUTHENTIK_RELEASE}" "${APPS_NS}"

info "stage 'authentik' complete"
