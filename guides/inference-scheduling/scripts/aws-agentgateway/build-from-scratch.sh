#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

INITIAL_DECODE_REPLICAS="${INITIAL_DECODE_REPLICAS:-2}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Cold-start workflow for AWS/EKS + agentgateway:
  1. create the cluster and small system nodegroup
  2. install agentgateway, monitoring, and the inference-scheduling guide
  3. create zero-size GPU candidate nodegroups
  4. race GPU nodegroup bring-up
  5. scale the decode deployment
EOF
}

require_cmds bash
require_aws_profile

"${SCRIPT_DIR}/cluster.sh" create
INITIAL_DECODE_REPLICAS=0 "${SCRIPT_DIR}/install-stack.sh"
"${SCRIPT_DIR}/capacity.sh" ensure-nodegroups

if (( INITIAL_DECODE_REPLICAS > 0 )); then
  TARGET_DECODE_REPLICAS="${INITIAL_DECODE_REPLICAS}" \
  "${SCRIPT_DIR}/scale-decode-with-capacity.sh"
fi

log_success "Cold-start AWS/EKS workflow completed."
