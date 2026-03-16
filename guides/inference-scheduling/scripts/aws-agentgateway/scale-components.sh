#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DECODE_REPLICAS="${DECODE_REPLICAS:-}"
EPP_REPLICAS="${EPP_REPLICAS:-}"
GATEWAY_REPLICAS="${GATEWAY_REPLICAS:-}"
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS:-7200}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Scale one or more inference-scheduling deployments in-place.

Environment:
  AWS_PROFILE               Default: ${AWS_PROFILE}
  AWS_REGION                Default: ${AWS_REGION}
  NAMESPACE                 Default: ${NAMESPACE}
  RELEASE_NAME_POSTFIX      Default: ${RELEASE_NAME_POSTFIX}
  DECODE_REPLICAS           Optional
  EPP_REPLICAS              Optional
  GATEWAY_REPLICAS          Optional
  ROLLOUT_TIMEOUT_SECONDS   Default: ${ROLLOUT_TIMEOUT_SECONDS}
EOF
}

require_cmds aws eksctl kubectl
require_aws_profile
cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
ensure_cluster_credentials

if [[ -z "${DECODE_REPLICAS}" && -z "${EPP_REPLICAS}" && -z "${GATEWAY_REPLICAS}" ]]; then
  usage
  exit 1
fi

if [[ -n "${DECODE_REPLICAS}" ]]; then
  scale_deployment "${NAMESPACE}" "${DECODE_DEPLOYMENT}" "${DECODE_REPLICAS}" "${ROLLOUT_TIMEOUT_SECONDS}"
fi

if [[ -n "${EPP_REPLICAS}" ]]; then
  scale_deployment "${NAMESPACE}" "${EPP_DEPLOYMENT}" "${EPP_REPLICAS}" "${ROLLOUT_TIMEOUT_SECONDS}"
fi

if [[ -n "${GATEWAY_REPLICAS}" ]]; then
  scale_deployment "${NAMESPACE}" "${GATEWAY_DEPLOYMENT}" "${GATEWAY_REPLICAS}" "${ROLLOUT_TIMEOUT_SECONDS}"
fi
