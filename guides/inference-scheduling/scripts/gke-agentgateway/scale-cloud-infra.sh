#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-status}"
CPU_NODES="${CPU_NODES:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <status|cpu|ensure-queued|ensure-reserved|ensure-h100>

Environment:
  PROJECT_ID         Required GCP project
  CPU_NODES          Required for cpu action
  DEFAULT_NODEPOOL   Default: ${DEFAULT_NODEPOOL}
  H100_CAPACITY_MODE queued | reservation (default: ${H100_CAPACITY_MODE})
  H100_NODEPOOL      Default: ${H100_NODEPOOL}
  H100_RESERVED_NODEPOOL
                     Default: ${H100_RESERVED_NODEPOOL}
  H100_RESERVED_RESERVATION_NAME
                     Default: ${H100_RESERVED_RESERVATION_NAME}
  QUEUE_CANDIDATES   Optional candidate list:
                     pool|zone|machine_type|gpu_type|gpu_count|optional_max_nodes;...
EOF
}

ensure_queued_pool() {
  ensure_queue_candidate_pools
}

ensure_reserved_pool_action() {
  ensure_reserved_pool
}

ensure_h100_pool_action() {
  ensure_h100_capacity_pools
}

scale_cpu_pool() {
  [[ -n "${CPU_NODES}" ]] || fail "Set CPU_NODES for the cpu action."
  if [[ "${CPU_NODES}" == "0" ]]; then
    ensure_idle_namespace "${NAMESPACE}"
    ensure_idle_namespace "${MONITORING_NAMESPACE}"
    ensure_idle_namespace "${GATEWAY_NAMESPACE}"
  fi

  gcloud container clusters resize "${CLUSTER_NAME}" \
    --node-pool "${DEFAULT_NODEPOOL}" \
    --zone "${CLUSTER_ZONE}" \
    --project "${PROJECT_ID}" \
    --num-nodes "${CPU_NODES}" \
    --quiet >/dev/null
  wait_for_node_count "${DEFAULT_NODEPOOL}" "${CPU_NODES}" 1800
  log_success "Scaled ${DEFAULT_NODEPOOL} to ${CPU_NODES} node(s)."
}

show_status() {
  print_status_block "Node Pools" \
    gcloud container node-pools list --cluster "${CLUSTER_NAME}" --zone "${CLUSTER_ZONE}" --project "${PROJECT_ID}"
  print_status_block "Nodes" kubectl get nodes -L cloud.google.com/gke-nodepool
}

require_cmds gcloud kubectl
require_project_id
ensure_supported_capacity_mode
cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
ensure_cluster_credentials

case "${ACTION}" in
  status)
    show_status
    ;;
  cpu)
    scale_cpu_pool
    ;;
  ensure-queued)
    ensure_queued_pool
    ;;
  ensure-reserved)
    ensure_reserved_pool_action
    ;;
  ensure-h100)
    ensure_h100_pool_action
    ;;
  *)
    usage
    exit 1
    ;;
esac
