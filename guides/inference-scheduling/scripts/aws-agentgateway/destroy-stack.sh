#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Destroys the AWS/EKS + agentgateway inference-scheduling stack, but leaves the
cluster intact.
EOF
}

require_cmds aws eksctl kubectl helm helmfile
require_aws_profile

if ! cluster_exists; then
  log_info "Cluster ${CLUSTER_NAME} does not exist."
  exit 0
fi

ensure_cluster_credentials

if namespace_exists "${NAMESPACE}"; then
  delete_httproute
  delete_smoke_client "${NAMESPACE}" "${RELEASE_NAME_POSTFIX}-smoke-client"
fi

cd "${GUIDE_DIR}"
if namespace_exists "${NAMESPACE}"; then
  helmfile destroy -e "${GATEWAY_PROVIDER}" -n "${NAMESPACE}" || true
fi

if helm_release_exists llmd "${MONITORING_NAMESPACE}"; then
  helm uninstall llmd -n "${MONITORING_NAMESPACE}" >/dev/null
fi

if helm_release_exists agentgateway "${GATEWAY_NAMESPACE}"; then
  helm uninstall agentgateway -n "${GATEWAY_NAMESPACE}" >/dev/null
fi
if helm_release_exists agentgateway-crds "${GATEWAY_NAMESPACE}"; then
  helm uninstall agentgateway-crds -n "${GATEWAY_NAMESPACE}" >/dev/null
fi

if namespace_exists "${NAMESPACE}"; then
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null
fi
kubectl delete namespace "${MONITORING_NAMESPACE}" --ignore-not-found >/dev/null
kubectl delete namespace "${GATEWAY_NAMESPACE}" --ignore-not-found >/dev/null

log_success "Destroyed the AWS/EKS + agentgateway inference-scheduling stack."
