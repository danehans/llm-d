#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DELETE_CRDS="${DELETE_CRDS:-false}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Removes the inference-scheduling workload, monitoring stack, and agentgateway
control plane from the current cluster.

Environment:
  PROJECT_ID           Required GCP project
  NAMESPACE            Default: ${NAMESPACE}
  MONITORING_NAMESPACE Default: ${MONITORING_NAMESPACE}
  DELETE_CRDS          Default: ${DELETE_CRDS}
EOF
}

require_cmds gcloud kubectl helm helmfile
require_project_id
cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
ensure_cluster_credentials

if namespace_exists "${NAMESPACE}"; then
  delete_httproute
  if helm_release_exists "${INFRA_RELEASE}" "${NAMESPACE}" || helm_release_exists "${GAIE_RELEASE}" "${NAMESPACE}" || helm_release_exists "${MS_RELEASE}" "${NAMESPACE}"; then
    cd "${GUIDE_DIR}"
    export RELEASE_NAME_POSTFIX
    if [[ -n "${LLMD_INFRA_CHART}" ]]; then
      export LLMD_INFRA_CHART
    fi
    helmfile destroy -e "${GATEWAY_PROVIDER}" -n "${NAMESPACE}"
    log_success "Removed inference-scheduling releases from ${NAMESPACE}."
  else
    log_info "Inference-scheduling releases are already absent from ${NAMESPACE}."
  fi
else
  log_info "Namespace ${NAMESPACE} does not exist."
fi

if helm_release_exists llmd "${MONITORING_NAMESPACE}"; then
  helm uninstall llmd -n "${MONITORING_NAMESPACE}" >/dev/null
  log_success "Removed monitoring stack from ${MONITORING_NAMESPACE}."
else
  log_info "Monitoring stack is already absent from ${MONITORING_NAMESPACE}."
fi

if helm_release_exists agentgateway "${GATEWAY_NAMESPACE}" || helm_release_exists agentgateway-crds "${GATEWAY_NAMESPACE}"; then
  cd "${GATEWAY_DIR}"
  helmfile destroy -f agentgateway.helmfile.yaml
  log_success "Removed agentgateway releases from ${GATEWAY_NAMESPACE}."
else
  log_info "agentgateway releases are already absent from ${GATEWAY_NAMESPACE}."
fi

if [[ "${DELETE_CRDS}" == "true" ]]; then
  cd "${GATEWAY_DIR}"
  ./install-gateway-provider-dependencies.sh delete
  log_success "Removed Gateway API and GAIE CRDs."
fi

log_success "Stack teardown completed."
