#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TARGET_DECODE_REPLICAS="${TARGET_DECODE_REPLICAS:-}"
REQUEST_NAME="${REQUEST_NAME:-}"
NODEPOOL_READY_TIMEOUT_SECONDS="${NODEPOOL_READY_TIMEOUT_SECONDS:-1800}"
QUEUE_WAIT_TIMEOUT_SECONDS="${QUEUE_WAIT_TIMEOUT_SECONDS:-1800}"
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS:-7200}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Capacity-aware decode scale-up workflow:
  queued mode:
    1. determine how many additional decode replicas are needed
    2. create or race a queued H100 ProvisioningRequest for that delta
    3. watch the winning node pool until enough ready H100 nodes exist
    4. scale the decode deployment
  reservation mode:
    1. determine how many additional decode replicas are needed
    2. scale the decode deployment
    3. watch the reservation-backed node pool until enough ready H100 nodes exist
    4. wait for the decode rollout to finish

Environment:
  PROJECT_ID                     Required GCP project
  H100_CAPACITY_MODE             queued | reservation (default: ${H100_CAPACITY_MODE})
  TARGET_DECODE_REPLICAS         Required target replica count
  REQUEST_NAME                   Optional base request name
  NODEPOOL_READY_TIMEOUT_SECONDS Default: ${NODEPOOL_READY_TIMEOUT_SECONDS}
  QUEUE_WAIT_TIMEOUT_SECONDS     Default: ${QUEUE_WAIT_TIMEOUT_SECONDS}
  ROLLOUT_TIMEOUT_SECONDS        Default: ${ROLLOUT_TIMEOUT_SECONDS}
  QUEUE_CANDIDATES               Optional multi-zone race candidates
EOF
}

require_cmds bash kubectl gcloud
require_project_id
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

additional_decode_replicas=$(( TARGET_DECODE_REPLICAS - current_decode_replicas ))

if capacity_mode_is_reservation; then
  reservation_nodes_needed="$(required_h100_nodes_for_decode_replicas "${additional_decode_replicas}")"
  reservation_baseline="$(ready_node_count "${H100_RESERVED_NODEPOOL}")"
  reservation_target_ready=$(( reservation_baseline + reservation_nodes_needed ))

  nodepool_exists "${H100_RESERVED_NODEPOOL}" || fail "Reservation-backed node pool ${H100_RESERVED_NODEPOOL} does not exist."

  log_info "Scaling decode from ${current_decode_replicas} to ${TARGET_DECODE_REPLICAS} replica(s) using reservation-backed pool ${H100_RESERVED_NODEPOOL}."
  log_info "Waiting for ${H100_RESERVED_NODEPOOL} (${H100_RESERVED_ZONE}) to reach ${reservation_target_ready} ready H100 node(s); baseline=${reservation_baseline}, additional_nodes=${reservation_nodes_needed}."

  kubectl scale "deployment/${DECODE_DEPLOYMENT}" -n "${NAMESPACE}" --replicas="${TARGET_DECODE_REPLICAS}" >/dev/null
  wait_for_ready_node_count "${H100_RESERVED_NODEPOOL}" "${reservation_target_ready}" "${NODEPOOL_READY_TIMEOUT_SECONDS}"
  wait_for_rollout "${NAMESPACE}" "${DECODE_DEPLOYMENT}" "${TARGET_DECODE_REPLICAS}" "${ROLLOUT_TIMEOUT_SECONDS}"
  log_success "Decode scale-up completed on reservation-backed pool ${H100_RESERVED_NODEPOOL}."
  exit 0
fi

if [[ -z "${REQUEST_NAME}" ]]; then
  if (( current_decode_replicas == 0 )); then
    REQUEST_NAME="${RELEASE_NAME_POSTFIX}-bringup-${TARGET_DECODE_REPLICAS}x${H100_GPUS_PER_NODE}"
  else
    REQUEST_NAME="${RELEASE_NAME_POSTFIX}-scaleout-${additional_decode_replicas}x${H100_GPUS_PER_NODE}"
  fi
fi

declare -A baseline_ready_counts=()
while IFS= read -r spec; do
  [[ -n "${spec}" ]] || continue
  parse_queue_candidate "${spec}"
  baseline_ready_counts["${CANDIDATE_POOL}"]="$(ready_node_count "${CANDIDATE_POOL}")"
done < <(queue_candidate_specs)

winner_request_name="${REQUEST_NAME}"
winner_pool="${REQUEST_NODEPOOL:-${H100_NODEPOOL}}"
winner_zone="${REQUEST_ZONE:-${NODE_LOCATION}}"

if [[ -n "${QUEUE_CANDIDATES}" ]]; then
  winner_env_file="$(mktemp)"
  REQUEST_NAME="${REQUEST_NAME}" \
  POD_COUNT="${additional_decode_replicas}" \
  WAIT_TIMEOUT_SECONDS="${QUEUE_WAIT_TIMEOUT_SECONDS}" \
  WINNER_ENV_FILE="${winner_env_file}" \
  "${SCRIPT_DIR}/queue-capacity.sh" race
  source "${winner_env_file}"
  rm -f "${winner_env_file}"
  winner_request_name="${WINNER_REQUEST_NAME}"
  winner_pool="${WINNER_NODEPOOL}"
  winner_zone="${WINNER_ZONE}"
else
  REQUEST_NAME="${REQUEST_NAME}" \
  POD_COUNT="${additional_decode_replicas}" \
  WAIT_TIMEOUT_SECONDS="${QUEUE_WAIT_TIMEOUT_SECONDS}" \
  "${SCRIPT_DIR}/queue-capacity.sh" recreate
fi

baseline_ready="${baseline_ready_counts["${winner_pool}"]:-0}"
target_ready=$(( baseline_ready + additional_decode_replicas ))

log_info "Waiting for ${winner_pool} (${winner_zone}) to reach ${target_ready} ready H100 node(s); baseline=${baseline_ready}, additional=${additional_decode_replicas}."
wait_for_ready_node_count "${winner_pool}" "${target_ready}" "${NODEPOOL_READY_TIMEOUT_SECONDS}"
log_success "${winner_pool} has enough ready H100 nodes for the scale-up."

REQUEST_NAME="${winner_request_name}" \
DECODE_REPLICAS="${TARGET_DECODE_REPLICAS}" \
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS}" \
"${SCRIPT_DIR}/scale-components.sh"

log_success "Decode scale-up completed with request ${winner_request_name} on ${winner_pool} (${winner_zone})."
