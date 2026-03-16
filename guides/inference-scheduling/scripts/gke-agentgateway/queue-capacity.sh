#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-help}"
REQUEST_NAME="${REQUEST_NAME:-${RELEASE_NAME_POSTFIX}-scaleout-6x${H100_GPUS_PER_NODE}}"
POD_TEMPLATE_NAME="${POD_TEMPLATE_NAME:-${RELEASE_NAME_POSTFIX}-a3-${H100_GPUS_PER_NODE}xh100}"
POD_COUNT="${POD_COUNT:-6}"
GPU_COUNT="${GPU_COUNT:-${H100_GPUS_PER_NODE}}"
CPU_REQUEST="${CPU_REQUEST:-32}"
MEMORY_REQUEST="${MEMORY_REQUEST:-100Gi}"
MAX_RUN_DURATION_SECONDS="${MAX_RUN_DURATION_SECONDS:-43200}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-1800}"
SLEEP_SECONDS="${SLEEP_SECONDS:-15}"
REQUEST_NODEPOOL="${REQUEST_NODEPOOL:-${H100_NODEPOOL}}"
REQUEST_ZONE="${REQUEST_ZONE:-${NODE_LOCATION}}"
WINNER_ENV_FILE="${WINNER_ENV_FILE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <print|dry-run|apply|watch|status|delete|recreate|race>

Environment:
  PROJECT_ID                Required GCP project
  NAMESPACE                 Default: ${NAMESPACE}
  REQUEST_NAME              Default: ${REQUEST_NAME}
  POD_TEMPLATE_NAME         Default: ${POD_TEMPLATE_NAME}
  POD_COUNT                 Default: ${POD_COUNT}
  GPU_COUNT                 Default: ${GPU_COUNT}
  CPU_REQUEST               Default: ${CPU_REQUEST}
  MEMORY_REQUEST            Default: ${MEMORY_REQUEST}
  MAX_RUN_DURATION_SECONDS  Default: ${MAX_RUN_DURATION_SECONDS}
  WAIT_TIMEOUT_SECONDS      Default: ${WAIT_TIMEOUT_SECONDS}
  SLEEP_SECONDS             Default: ${SLEEP_SECONDS}
  REQUEST_NODEPOOL          Default: ${REQUEST_NODEPOOL}
  REQUEST_ZONE              Default: ${REQUEST_ZONE}
  WINNER_ENV_FILE           Optional file path written by race mode
  QUEUE_CANDIDATES          Optional candidate list:
                            pool|zone|machine_type|gpu_type|gpu_count|optional_max_nodes;...
EOF
}

render_manifest() {
  cat <<EOF
apiVersion: v1
kind: PodTemplate
metadata:
  name: ${POD_TEMPLATE_NAME}
  namespace: ${NAMESPACE}
  labels:
    cloud.google.com/apply-warden-policies: "true"
template:
  spec:
    restartPolicy: Never
    nodeSelector:
      cloud.google.com/gke-nodepool: ${REQUEST_NODEPOOL}
      topology.kubernetes.io/zone: ${REQUEST_ZONE}
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: cloud.google.com/gke-queued
        operator: Equal
        value: "true"
        effect: NoSchedule
    containers:
      - name: reserve
        image: registry.k8s.io/pause:3.10
        resources:
          requests:
            nvidia.com/gpu: "${GPU_COUNT}"
            cpu: "${CPU_REQUEST}"
            memory: "${MEMORY_REQUEST}"
          limits:
            nvidia.com/gpu: "${GPU_COUNT}"
            cpu: "${CPU_REQUEST}"
            memory: "${MEMORY_REQUEST}"
---
apiVersion: autoscaling.x-k8s.io/v1
kind: ProvisioningRequest
metadata:
  name: ${REQUEST_NAME}
  namespace: ${NAMESPACE}
spec:
  provisioningClassName: queued-provisioning.gke.io
  parameters:
    maxRunDurationSeconds: "${MAX_RUN_DURATION_SECONDS}"
  podSets:
    - count: ${POD_COUNT}
      podTemplateRef:
        name: ${POD_TEMPLATE_NAME}
EOF
}

print_status() {
  kubectl get provisioningrequest "${REQUEST_NAME}" -n "${NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"|"}{.reason}{"|"}{.message}{"\n"}{end}'
}

wait_for_provisioned() {
  local deadline
  local state

  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
  while true; do
    state="$(print_status)"
    printf '%s\n' "${state}"

    if grep -q '^BookingExpired=True|' <<<"${state}"; then
      fail "ProvisioningRequest ${REQUEST_NAME} booking has expired."
    fi

    if grep -q '^Provisioned=True|' <<<"${state}"; then
      echo
      log_success "ProvisioningRequest ${REQUEST_NAME} is ready. Consume the nodes within roughly 10 minutes."
      return 0
    fi

    if grep -q '^Failed=True|' <<<"${state}"; then
      fail "ProvisioningRequest ${REQUEST_NAME} failed."
    fi

    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for ProvisioningRequest ${REQUEST_NAME} to become Provisioned."
    fi
    sleep "${SLEEP_SECONDS}"
  done
}

write_winner_env_file() {
  local request_name="$1"
  local pool="$2"
  local zone="$3"
  [[ -n "${WINNER_ENV_FILE}" ]] || return 0
  cat > "${WINNER_ENV_FILE}" <<EOF
WINNER_REQUEST_NAME=${request_name}
WINNER_NODEPOOL=${pool}
WINNER_ZONE=${zone}
EOF
}

watch_race_winner() {
  local -a request_names=("$@")
  local deadline
  local request_name
  local state
  local winner=""
  local winner_pool=""
  local winner_zone=""
  local spec
  local candidate_request_name

  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
  while true; do
    for spec in "${request_names[@]}"; do
      IFS='|' read -r candidate_request_name winner_pool winner_zone <<<"${spec}"
      state="$(kubectl get provisioningrequest "${candidate_request_name}" -n "${NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"|"}{.reason}{"|"}{.message}{"\n"}{end}' 2>/dev/null || true)"
      printf '[%s] %s\n' "${candidate_request_name}" "${state}"
      if grep -q '^Provisioned=True|' <<<"${state}" && ! grep -q '^BookingExpired=True|' <<<"${state}"; then
        winner="${candidate_request_name}"
        break
      fi
    done

    if [[ -n "${winner}" ]]; then
      break
    fi

    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for any candidate ProvisioningRequest to become Provisioned."
    fi
    sleep "${SLEEP_SECONDS}"
  done

  for spec in "${request_names[@]}"; do
    IFS='|' read -r candidate_request_name candidate_pool candidate_zone <<<"${spec}"
    if [[ "${candidate_request_name}" == "${winner}" ]]; then
      winner_pool="${candidate_pool}"
      winner_zone="${candidate_zone}"
      continue
    fi
    REQUEST_NAME="${candidate_request_name}" POD_TEMPLATE_NAME="${POD_TEMPLATE_NAME}-${candidate_pool}" REQUEST_NODEPOOL="${candidate_pool}" REQUEST_ZONE="${candidate_zone}" render_manifest | kubectl delete --ignore-not-found=true -f - >/dev/null
  done

  write_winner_env_file "${winner}" "${winner_pool}" "${winner_zone}"
  log_success "Race winner: ${winner} on ${winner_pool} (${winner_zone})."
}

race_requests() {
  local -a candidates=()
  local -a request_names=()
  local spec
  local pool
  local zone
  local machine_type
  local gpu_type
  local gpu_count
  local max_nodes
  local candidate_request_name
  local candidate_template_name

  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    candidates+=("${spec}")
  done < <(queue_candidate_specs)

  ensure_queue_candidate_pools

  for spec in "${candidates[@]}"; do
    IFS='|' read -r pool zone machine_type gpu_type gpu_count max_nodes <<<"${spec}"
    candidate_request_name="${REQUEST_NAME}-${pool}"
    candidate_template_name="${POD_TEMPLATE_NAME}-${pool}"

    REQUEST_NAME="${candidate_request_name}" \
    POD_TEMPLATE_NAME="${candidate_template_name}" \
    REQUEST_NODEPOOL="${pool}" \
    REQUEST_ZONE="${zone}" \
    GPU_COUNT="${gpu_count}" \
    render_manifest | kubectl delete --ignore-not-found=true -f - >/dev/null

    REQUEST_NAME="${candidate_request_name}" \
    POD_TEMPLATE_NAME="${candidate_template_name}" \
    REQUEST_NODEPOOL="${pool}" \
    REQUEST_ZONE="${zone}" \
    GPU_COUNT="${gpu_count}" \
    render_manifest | kubectl apply -f -

    request_names+=("${candidate_request_name}|${pool}|${zone}")
  done

  watch_race_winner "${request_names[@]}"
}

require_cmds kubectl gcloud
require_project_id
cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
ensure_cluster_credentials
namespace_exists "${NAMESPACE}" || fail "Namespace ${NAMESPACE} does not exist. Install the stack first."
if [[ "${ACTION}" == "race" ]]; then
  ensure_queue_candidate_pools
else
  nodepool_exists "${REQUEST_NODEPOOL}" || fail "Queued H100 pool ${REQUEST_NODEPOOL} does not exist."
fi

case "${ACTION}" in
  print)
    render_manifest
    ;;
  dry-run)
    render_manifest | kubectl apply --dry-run=server -f -
    ;;
  apply)
    render_manifest | kubectl apply -f -
    wait_for_provisioned
    ;;
  watch)
    provisioning_request_exists "${NAMESPACE}" "${REQUEST_NAME}" || fail "ProvisioningRequest ${NAMESPACE}/${REQUEST_NAME} does not exist."
    wait_for_provisioned
    ;;
  status)
    print_status
    ;;
  delete)
    render_manifest | kubectl delete --ignore-not-found=true -f -
    ;;
  recreate)
    render_manifest | kubectl delete --ignore-not-found=true -f -
    render_manifest | kubectl apply -f -
    wait_for_provisioned
    ;;
  race)
    race_requests
    ;;
  *)
    usage
    exit 1
    ;;
esac
