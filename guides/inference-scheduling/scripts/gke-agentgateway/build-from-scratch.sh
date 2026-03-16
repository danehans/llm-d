#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

INITIAL_DECODE_REPLICAS="${INITIAL_DECODE_REPLICAS:-2}"
BRINGUP_REQUEST_NAME="${BRINGUP_REQUEST_NAME:-${RELEASE_NAME_POSTFIX}-bringup-${INITIAL_DECODE_REPLICAS}x${H100_GPUS_PER_NODE}}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Cold-start workflow for GKE + agentgateway:
  1. create the cluster and H100 capacity pool definition
  2. ensure a CPU node is available
  3. install agentgateway, monitoring, and the inference-scheduling guide
  4. request or consume H100 capacity for the initial decode replicas
  5. scale the decode deployment to the requested replica count

Environment:
  PROJECT_ID               Required GCP project
  H100_CAPACITY_MODE       queued | reservation (default: ${H100_CAPACITY_MODE})
  INITIAL_DECODE_REPLICAS  Default: ${INITIAL_DECODE_REPLICAS}
  LLMD_INFRA_CHART         Optional local llm-d-infra chart path
EOF
}

require_cmds bash
require_project_id

"${SCRIPT_DIR}/cluster.sh" create
CPU_NODES=1 "${SCRIPT_DIR}/scale-cloud-infra.sh" cpu
INITIAL_DECODE_REPLICAS=0 "${SCRIPT_DIR}/install-stack.sh"

if (( INITIAL_DECODE_REPLICAS > 0 )); then
  if capacity_mode_is_queued; then
    if [[ -n "${QUEUE_CANDIDATES:-}" ]]; then
      winner_env_file="$(mktemp)"
      REQUEST_NAME="${BRINGUP_REQUEST_NAME}" \
      POD_COUNT="${INITIAL_DECODE_REPLICAS}" \
      WINNER_ENV_FILE="${winner_env_file}" \
      "${SCRIPT_DIR}/queue-capacity.sh" race
      source "${winner_env_file}"
      rm -f "${winner_env_file}"
    else
      REQUEST_NAME="${BRINGUP_REQUEST_NAME}" \
      POD_COUNT="${INITIAL_DECODE_REPLICAS}" \
      "${SCRIPT_DIR}/queue-capacity.sh" recreate
      WINNER_REQUEST_NAME="${BRINGUP_REQUEST_NAME}"
    fi

    REQUEST_NAME="${WINNER_REQUEST_NAME}" \
    DECODE_REPLICAS="${INITIAL_DECODE_REPLICAS}" \
    "${SCRIPT_DIR}/scale-components.sh"
  else
    TARGET_DECODE_REPLICAS="${INITIAL_DECODE_REPLICAS}" \
    "${SCRIPT_DIR}/scale-decode-with-capacity.sh"
  fi
fi

log_success "Cold-start workflow completed."
