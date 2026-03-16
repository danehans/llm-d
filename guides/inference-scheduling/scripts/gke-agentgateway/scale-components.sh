#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DECODE_REPLICAS="${DECODE_REPLICAS:-}"
EPP_REPLICAS="${EPP_REPLICAS:-}"
GATEWAY_REPLICAS="${GATEWAY_REPLICAS:-}"
REQUEST_NAME="${REQUEST_NAME:-}"
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS:-7200}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Scale one or more inference-scheduling deployments in-place.

Environment:
  PROJECT_ID                 Required GCP project
  NAMESPACE                  Default: ${NAMESPACE}
  RELEASE_NAME_POSTFIX       Default: ${RELEASE_NAME_POSTFIX}
  DECODE_REPLICAS            Optional
  EPP_REPLICAS               Optional
  GATEWAY_REPLICAS           Optional
  REQUEST_NAME               Optional. Required when scaling decode up.
  ROLLOUT_TIMEOUT_SECONDS    Default: ${ROLLOUT_TIMEOUT_SECONDS}
EOF
}

require_cmds kubectl gcloud
require_project_id
ensure_supported_capacity_mode
cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
ensure_cluster_credentials

if [[ -z "${DECODE_REPLICAS}" && -z "${EPP_REPLICAS}" && -z "${GATEWAY_REPLICAS}" ]]; then
  usage
  exit 1
fi

if [[ -n "${DECODE_REPLICAS}" ]]; then
  current_decode_replicas="$(deployment_replica_count "${NAMESPACE}" "${DECODE_DEPLOYMENT}")"
  current_decode_replicas="${current_decode_replicas:-0}"

  if (( DECODE_REPLICAS > current_decode_replicas )); then
    additional_decode_replicas=$(( DECODE_REPLICAS - current_decode_replicas ))
    if capacity_mode_is_queued; then
      if [[ -z "${REQUEST_NAME}" ]]; then
        if (( current_decode_replicas == 0 )); then
          REQUEST_NAME="${RELEASE_NAME_POSTFIX}-bringup-${DECODE_REPLICAS}x${H100_GPUS_PER_NODE}"
        else
          REQUEST_NAME="${RELEASE_NAME_POSTFIX}-scaleout-${additional_decode_replicas}x${H100_GPUS_PER_NODE}"
        fi
      fi

      require_active_capacity_request "${NAMESPACE}" "${REQUEST_NAME}" "${additional_decode_replicas}"
    else
      nodepool_exists "${H100_RESERVED_NODEPOOL}" || fail "Reservation-backed node pool ${H100_RESERVED_NODEPOOL} does not exist."
    fi
  fi

  scale_deployment "${NAMESPACE}" "${DECODE_DEPLOYMENT}" "${DECODE_REPLICAS}" "${ROLLOUT_TIMEOUT_SECONDS}"
fi

if [[ -n "${EPP_REPLICAS}" ]]; then
  scale_deployment "${NAMESPACE}" "${EPP_DEPLOYMENT}" "${EPP_REPLICAS}" "${ROLLOUT_TIMEOUT_SECONDS}"
fi

if [[ -n "${GATEWAY_REPLICAS}" ]]; then
  scale_deployment "${NAMESPACE}" "${GATEWAY_DEPLOYMENT}" "${GATEWAY_REPLICAS}" "${ROLLOUT_TIMEOUT_SECONDS}"
fi
