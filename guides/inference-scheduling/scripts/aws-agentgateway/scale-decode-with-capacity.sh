#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TARGET_DECODE_REPLICAS="${TARGET_DECODE_REPLICAS:-}"
NODEGROUP_READY_TIMEOUT_SECONDS="${NODEGROUP_READY_TIMEOUT_SECONDS:-3600}"
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS:-7200}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Capacity-aware decode scale-up workflow:
  1. determine how many GPU nodes are required for the target decode replicas
  2. acquire cloud GPU capacity for that target
  3. scale decode

Environment:
  AWS_PROFILE                     Default: ${AWS_PROFILE}
  AWS_REGION                      Default: ${AWS_REGION}
  GPU_CAPACITY_MODE               Default: ${GPU_CAPACITY_MODE}
  TARGET_DECODE_REPLICAS          Required target replica count
  NODEGROUP_READY_TIMEOUT_SECONDS Default: ${NODEGROUP_READY_TIMEOUT_SECONDS}
  GPU_CANDIDATE_AZS               Optional comma-separated AZ list
EOF
}

require_cmds aws eksctl kubectl bash
require_aws_profile
ensure_supported_capacity_mode
cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
ensure_cluster_credentials
namespace_exists "${NAMESPACE}" || fail "Namespace ${NAMESPACE} does not exist."
deployment_exists "${DECODE_DEPLOYMENT}" "${NAMESPACE}" || fail "Deployment ${NAMESPACE}/${DECODE_DEPLOYMENT} does not exist."

[[ -n "${TARGET_DECODE_REPLICAS}" ]] || {
  usage
  exit 1
}

current_decode_replicas="$(deployment_replica_count "${NAMESPACE}" "${DECODE_DEPLOYMENT}")"
current_decode_replicas="${current_decode_replicas:-0}"
if (( TARGET_DECODE_REPLICAS <= current_decode_replicas )); then
  fail "TARGET_DECODE_REPLICAS=${TARGET_DECODE_REPLICAS} must be greater than current decode replicas (${current_decode_replicas})."
fi

required_gpu_nodes="$(required_gpu_nodes_for_decode_replicas "${TARGET_DECODE_REPLICAS}")"
winner_env_file="$(mktemp)"
trap 'rm -f "${winner_env_file}"' EXIT

TARGET_GPU_NODES="${required_gpu_nodes}" \
WAIT_TIMEOUT_SECONDS="${NODEGROUP_READY_TIMEOUT_SECONDS}" \
WINNER_ENV_FILE="${winner_env_file}" \
"${SCRIPT_DIR}/capacity.sh" race

source "${winner_env_file}"
wait_for_ready_node_count "${WINNER_NODEGROUP}" "${required_gpu_nodes}" "${NODEGROUP_READY_TIMEOUT_SECONDS}"

DECODE_REPLICAS="${TARGET_DECODE_REPLICAS}" \
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS}" \
"${SCRIPT_DIR}/scale-components.sh"

log_success "Decode scale-up completed on ${WINNER_NODEGROUP} in ${WINNER_AZ}."
