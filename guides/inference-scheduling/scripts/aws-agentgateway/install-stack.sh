#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

INITIAL_DECODE_REPLICAS="${INITIAL_DECODE_REPLICAS:-0}"
GATEWAY_TIMEOUT_SECONDS="${GATEWAY_TIMEOUT_SECONDS:-1800}"
WORKLOAD_TIMEOUT_SECONDS="${WORKLOAD_TIMEOUT_SECONDS:-7200}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Installs the AWS/EKS + agentgateway inference-scheduling stack into an existing
cluster and applies the HTTPRoute with the current RELEASE_NAME_POSTFIX.

Environment:
  AWS_PROFILE               Default: ${AWS_PROFILE}
  AWS_REGION                Default: ${AWS_REGION}
  NAMESPACE                 Default: ${NAMESPACE}
  RELEASE_NAME_POSTFIX      Default: ${RELEASE_NAME_POSTFIX}
  INITIAL_DECODE_REPLICAS   Default: ${INITIAL_DECODE_REPLICAS}
  LLMD_INFRA_CHART          Optional local llm-d-infra chart path
EOF
}

require_cmds aws eksctl kubectl helm helmfile
require_aws_profile
cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist. Run cluster.sh create first."
ensure_cluster_credentials
ensure_system_nodes 1

if (( INITIAL_DECODE_REPLICAS > 0 )); then
  fail "INITIAL_DECODE_REPLICAS must be 0 for this script. Install the stack first, then use scale-decode-with-capacity.sh."
fi

cd "${GATEWAY_DIR}"
./install-gateway-provider-dependencies.sh

if helm_release_exists agentgateway "${GATEWAY_NAMESPACE}" && helm_release_exists agentgateway-crds "${GATEWAY_NAMESPACE}"; then
  log_info "agentgateway releases already exist."
else
  helmfile apply -f agentgateway.helmfile.yaml
  log_success "Installed agentgateway."
fi
wait_for_rollout "${GATEWAY_NAMESPACE}" agentgateway 1 "${GATEWAY_TIMEOUT_SECONDS}"

if helm_release_exists llmd "${MONITORING_NAMESPACE}"; then
  log_info "Monitoring stack already exists in ${MONITORING_NAMESPACE}."
else
  "${MONITORING_SCRIPT}"
  log_success "Installed monitoring stack."
fi

ensure_namespace "${NAMESPACE}"
ensure_hf_secret

MS_VALUES_OVERLAY="$(render_ms_values_overlay "${INITIAL_DECODE_REPLICAS}")"
trap 'rm -f "${MS_VALUES_OVERLAY:-}"' EXIT
export MS_VALUES_OVERLAY
export RELEASE_NAME_POSTFIX
if [[ -n "${LLMD_INFRA_CHART}" ]]; then
  export LLMD_INFRA_CHART
fi

cd "${GUIDE_DIR}"
helmfile apply -e "${GATEWAY_PROVIDER}" -n "${NAMESPACE}"
unset MS_VALUES_OVERLAY

wait_for_rollout "${NAMESPACE}" "${GATEWAY_DEPLOYMENT}" 1 "${WORKLOAD_TIMEOUT_SECONDS}"
wait_for_rollout "${NAMESPACE}" "${EPP_DEPLOYMENT}" 1 "${WORKLOAD_TIMEOUT_SECONDS}"

apply_httproute
wait_for_gateway_programmed "${GATEWAY_TIMEOUT_SECONDS}"
wait_for_httproute_ready "${GATEWAY_TIMEOUT_SECONDS}"

log_success "Installed the AWS/EKS + agentgateway inference-scheduling stack."
