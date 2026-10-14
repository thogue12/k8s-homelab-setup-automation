#!/usr/bin/env bash
#
# Stage 4 (storage): Rancher local-path provisioner as the default StorageClass.
# Migrated from installing-authentik-with-helm.md Step 1.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

stage_init "storage"

readonly LOCAL_PATH_PROVISIONER_VERSION="${KB_LOCAL_PATH_PROVISIONER_VERSION}"
readonly LOCAL_PATH_PROVISIONER_MANIFEST="https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml"

readonly PROVISIONER_DEPLOY="local-path-provisioner"
readonly PROVISIONER_NS="local-path-storage"
readonly STORAGECLASS_NAME="local-path"
readonly DEFAULT_CLASS_ANNOTATION="storageclass.kubernetes.io/is-default-class"

# Count StorageClasses carrying the default annotation (no jq dependency).
default_class_count() {
  kubectl get storageclass \
    -o jsonpath="{range .items[?(.metadata.annotations.${DEFAULT_CLASS_ANNOTATION//./\\.}=='true')]}{.metadata.name}{'\n'}{end}" \
    2>/dev/null | grep -c . || true
}

require_cluster

# Skip the apply when the provisioner (at the pinned version) and the default
# annotation are already present. A version mismatch falls through to apply so
# preflight's version-drift check can actually converge.
skip_apply=false
if resource_exists deploy "${PROVISIONER_DEPLOY}" "${PROVISIONER_NS}" \
  && [ "$(image_tag "$(kubectl -n "${PROVISIONER_NS}" get deploy "${PROVISIONER_DEPLOY}" \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)")" \
       = "${LOCAL_PATH_PROVISIONER_VERSION}" ] \
  && [ "$(kubectl get storageclass "${STORAGECLASS_NAME}" \
            -o jsonpath="{.metadata.annotations.${DEFAULT_CLASS_ANNOTATION//./\\.}}" \
            2>/dev/null)" = "true" ]; then
  info "local-path provisioner and default annotation already present; skipping apply"
  skip_apply=true
fi

if [ "${skip_apply}" = false ]; then
  info "installing Rancher local-path provisioner (${LOCAL_PATH_PROVISIONER_VERSION})"
  kapply -f "${LOCAL_PATH_PROVISIONER_MANIFEST}"

  info "marking StorageClass '${STORAGECLASS_NAME}' as the cluster default"
  kubectl patch storageclass "${STORAGECLASS_NAME}" \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

# Exactly one StorageClass must be default.
default_count="$(default_class_count)"
if [ "${default_count}" -ne 1 ]; then
  err "expected exactly one default StorageClass, found ${default_count}; current StorageClasses:"
  kubectl get storageclass >&2 || true
  die "default StorageClass misconfigured (found ${default_count}, expected 1)"
fi

info "verified exactly one default StorageClass ('${STORAGECLASS_NAME}')"
info "stage 'storage' complete"
