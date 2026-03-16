#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-status}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <create|delete|status>

Environment:
  AWS_PROFILE           Default: ${AWS_PROFILE}
  AWS_REGION            Default: ${AWS_REGION}
  CLUSTER_NAME          Default: ${CLUSTER_NAME}
  CLUSTER_VERSION       Default: ${CLUSTER_VERSION}
  SYSTEM_NODEGROUP      Default: ${SYSTEM_NODEGROUP}
  SYSTEM_INSTANCE_TYPE  Default: ${SYSTEM_INSTANCE_TYPE}
  GPU_INSTANCE_TYPE     Default: ${GPU_INSTANCE_TYPE}
  GPU_CANDIDATE_AZS     Optional comma-separated AZ list
EOF
}

create_cluster() {
  local zones_csv

  if cluster_exists; then
    log_info "Cluster ${CLUSTER_NAME} already exists."
  else
    zones_csv="$(effective_cluster_azs_csv)"
    [[ -n "${zones_csv}" ]] || fail "Could not determine candidate AZs for ${GPU_INSTANCE_TYPE} in ${AWS_REGION}."

    eksctl_cmd create cluster \
      --name "${CLUSTER_NAME}" \
      --version "${CLUSTER_VERSION}" \
      --with-oidc \
      --without-nodegroup \
      --zones "${zones_csv}" \
      --tags "$(common_tags)"
    log_success "Created cluster ${CLUSTER_NAME}."
  fi

  ensure_cluster_credentials
  create_system_nodegroup

  log_success "Cluster ${CLUSTER_NAME} is ready for the AWS + agentgateway workflow."
}

delete_cluster() {
  if ! cluster_exists; then
    cleanup_cluster_capacity_reservations
    log_info "Cluster ${CLUSTER_NAME} does not exist."
    return 0
  fi

  cleanup_cluster_capacity_reservations
  eksctl_cmd delete cluster --name "${CLUSTER_NAME}" --wait
  log_success "Deleted cluster ${CLUSTER_NAME}."
}

status_cluster() {
  if ! cluster_exists; then
    log_warn "Cluster ${CLUSTER_NAME} does not exist."
    return 0
  fi

  ensure_cluster_credentials
  print_status_block "Cluster" \
    aws_cmd eks describe-cluster --name "${CLUSTER_NAME}" \
      --query 'cluster.{name:name,status:status,version:version,endpoint:endpoint}' \
      --output yaml
  print_status_block "Nodegroups" aws_cmd eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --output table
  print_status_block "Nodes" kubectl get nodes -L eks.amazonaws.com/nodegroup
}

require_cmds aws eksctl kubectl
require_aws_profile
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
