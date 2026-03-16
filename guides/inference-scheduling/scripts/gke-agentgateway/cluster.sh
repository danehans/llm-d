#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-status}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <create|delete|status>

Environment:
  PROJECT_ID             Required GCP project
  CLUSTER_NAME           Default: ${CLUSTER_NAME}
  CLUSTER_ZONE           Default: ${CLUSTER_ZONE}
  NODE_LOCATION          Default: ${NODE_LOCATION}
  CLUSTER_VERSION        Optional exact GKE version
  DEFAULT_NODEPOOL       Default: ${DEFAULT_NODEPOOL}
  DEFAULT_NODE_COUNT     Default: ${DEFAULT_NODE_COUNT}
  DEFAULT_MACHINE_TYPE   Default: ${DEFAULT_MACHINE_TYPE}
  H100_CAPACITY_MODE     queued | reservation (default: ${H100_CAPACITY_MODE})
  H100_NODEPOOL          Default: ${H100_NODEPOOL}
  H100_MACHINE_TYPE      Default: ${H100_MACHINE_TYPE}
  H100_GPU_TYPE          Default: ${H100_GPU_TYPE}
  H100_MAX_NODES         Default: ${H100_MAX_NODES}
  H100_RESERVED_NODEPOOL Default: ${H100_RESERVED_NODEPOOL}
  H100_RESERVED_ZONE     Default: ${H100_RESERVED_ZONE}
  H100_RESERVED_MACHINE_TYPE
                         Default: ${H100_RESERVED_MACHINE_TYPE}
  H100_RESERVED_RESERVATION_NAME
                         Default: ${H100_RESERVED_RESERVATION_NAME}
  QUEUE_CANDIDATES       Optional candidate list:
                         pool|zone|machine_type|gpu_type|gpu_count|optional_max_nodes;...
EOF
}

create_cluster() {
  local cmd

  if cluster_exists; then
    log_info "Cluster ${CLUSTER_NAME} already exists."
  else
    cmd=(
      gcloud container clusters create "${CLUSTER_NAME}"
      --project "${PROJECT_ID}"
      --zone "${CLUSTER_ZONE}"
      --machine-type "${DEFAULT_MACHINE_TYPE}"
      --num-nodes "${DEFAULT_NODE_COUNT}"
    )
    if [[ -n "${CLUSTER_VERSION}" ]]; then
      cmd+=(--cluster-version "${CLUSTER_VERSION}")
    fi
    "${cmd[@]}"
    log_success "Created cluster ${CLUSTER_NAME}."
  fi

  ensure_cluster_credentials

  ensure_h100_capacity_pools

  log_success "Cluster ${CLUSTER_NAME} is ready for the GKE + agentgateway workflow."
}

delete_cluster() {
  if ! cluster_exists; then
    log_info "Cluster ${CLUSTER_NAME} does not exist."
    return 0
  fi

  gcloud container clusters delete "${CLUSTER_NAME}" \
    --project "${PROJECT_ID}" \
    --zone "${CLUSTER_ZONE}" \
    --quiet
  log_success "Deleted cluster ${CLUSTER_NAME}."
}

status_cluster() {
  if ! cluster_exists; then
    log_warn "Cluster ${CLUSTER_NAME} does not exist."
    return 0
  fi

  ensure_cluster_credentials
  print_status_block "Cluster" \
    gcloud container clusters describe "${CLUSTER_NAME}" --project "${PROJECT_ID}" --zone "${CLUSTER_ZONE}" \
      --format='yaml(name,location,status,currentMasterVersion,currentNodeVersion)'
  print_status_block "Node Pools" \
    gcloud container node-pools list --cluster "${CLUSTER_NAME}" --project "${PROJECT_ID}" --zone "${CLUSTER_ZONE}"
  print_status_block "Nodes" kubectl get nodes -L cloud.google.com/gke-nodepool
}

require_cmds gcloud kubectl
require_project_id
ensure_supported_capacity_mode

case "${ACTION}" in
  create)
    create_cluster
    ;;
  delete)
    delete_cluster
    ;;
  status)
    status_cluster
    ;;
  *)
    usage
    exit 1
    ;;
esac
