#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../../.." && pwd)"
GUIDE_DIR="${REPO_ROOT}/guides/inference-scheduling"
GATEWAY_DIR="${REPO_ROOT}/guides/prereq/gateway-provider"
MONITORING_SCRIPT="${REPO_ROOT}/docs/monitoring/scripts/install-prometheus-grafana.sh"

AWS_PROFILE="${AWS_PROFILE:-552234177002_Eng-FE-Restricted}"
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-llmd-agw-is-aws}"
CLUSTER_VERSION="${CLUSTER_VERSION:-1.34}"
KUBECONFIG_ALIAS="${KUBECONFIG_ALIAS:-${CLUSTER_NAME}}"
SYSTEM_NODEGROUP="${SYSTEM_NODEGROUP:-system-ng}"
SYSTEM_INSTANCE_TYPE="${SYSTEM_INSTANCE_TYPE:-m6i.xlarge}"
SYSTEM_NODE_COUNT="${SYSTEM_NODE_COUNT:-1}"
SYSTEM_NODE_VOLUME_SIZE_GB="${SYSTEM_NODE_VOLUME_SIZE_GB:-100}"
GPU_CAPACITY_MODE="${GPU_CAPACITY_MODE:-on-demand}"
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-p5.48xlarge}"
GPU_GPUS_PER_NODE="${GPU_GPUS_PER_NODE:-8}"
GPU_MAX_NODES="${GPU_MAX_NODES:-2}"
GPU_NODE_VOLUME_SIZE_GB="${GPU_NODE_VOLUME_SIZE_GB:-1000}"
GPU_CANDIDATE_AZS="${GPU_CANDIDATE_AZS:-}"
GPU_NODEGROUP_PREFIX="${GPU_NODEGROUP_PREFIX:-gpu-ng}"
ODCR_INSTANCE_PLATFORM="${ODCR_INSTANCE_PLATFORM:-Linux/UNIX}"
ODCR_INSTANCE_MATCH_CRITERIA="${ODCR_INSTANCE_MATCH_CRITERIA:-open}"
ODCR_PREFIX="${ODCR_PREFIX:-${CLUSTER_NAME}-odcr}"
ODCR_END_DATE_TYPE="${ODCR_END_DATE_TYPE:-unlimited}"
ODCR_END_DATE="${ODCR_END_DATE:-}"
DECODE_GPUS_PER_REPLICA="${DECODE_GPUS_PER_REPLICA:-2}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-llm-d-monitoring}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-agentgateway-system}"
NAMESPACE="${NAMESPACE:-llmd}"
RELEASE_NAME_POSTFIX="${RELEASE_NAME_POSTFIX:-is}"
GATEWAY_PROVIDER="${GATEWAY_PROVIDER:-agentgateway}"
HF_SECRET_NAME="${HF_SECRET_NAME:-llm-d-hf-token}"
LLMD_INFRA_CHART="${LLMD_INFRA_CHART:-}"

INFRA_RELEASE="infra-${RELEASE_NAME_POSTFIX}"
GAIE_RELEASE="gaie-${RELEASE_NAME_POSTFIX}"
MS_RELEASE="ms-${RELEASE_NAME_POSTFIX}"
GATEWAY_NAME="${INFRA_RELEASE}-inference-gateway"
GATEWAY_DEPLOYMENT="${INFRA_RELEASE}-inference-gateway"
EPP_DEPLOYMENT="${GAIE_RELEASE}-epp"
DECODE_DEPLOYMENT="${MS_RELEASE}-llm-d-modelservice-decode"
HTTPROUTE_NAME="llm-d-inference-scheduling"

COLOR_RESET=$'\e[0m'
COLOR_BLUE=$'\e[34m'
COLOR_GREEN=$'\e[32m'
COLOR_YELLOW=$'\e[33m'
COLOR_RED=$'\e[31m'

log_info() {
  echo "${COLOR_BLUE}ℹ️  $*${COLOR_RESET}"
}

log_warn() {
  echo "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"
}

log_success() {
  echo "${COLOR_GREEN}✅ $*${COLOR_RESET}"
}

log_error() {
  echo "${COLOR_RED}❌ $*${COLOR_RESET}" >&2
}

fail() {
  log_error "$*"
  exit 1
}

require_cmds() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "Required command not found: ${cmd}"
  done
}

aws_cmd() {
  AWS_PROFILE="${AWS_PROFILE}" aws --region "${AWS_REGION}" "$@"
}

eksctl_cmd() {
  AWS_PROFILE="${AWS_PROFILE}" eksctl --region "${AWS_REGION}" "$@"
}

require_aws_profile() {
  [[ -n "${AWS_PROFILE}" ]] || fail "Set AWS_PROFILE before running this script."
}

active_aws_identity() {
  aws_cmd sts get-caller-identity
}

ensure_supported_capacity_mode() {
  case "${GPU_CAPACITY_MODE}" in
    on-demand|odcr|capacity-block)
      ;;
    *)
      fail "Unsupported GPU_CAPACITY_MODE=${GPU_CAPACITY_MODE}. Use on-demand, odcr, or capacity-block."
      ;;
  esac
}

capacity_mode_is_on_demand() {
  [[ "${GPU_CAPACITY_MODE}" == "on-demand" ]]
}

capacity_mode_is_odcr() {
  [[ "${GPU_CAPACITY_MODE}" == "odcr" ]]
}

cluster_exists() {
  aws_cmd eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1
}

nodegroup_exists() {
  local nodegroup="$1"
  aws_cmd eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${nodegroup}" >/dev/null 2>&1
}

nodegroup_status() {
  local nodegroup="$1"
  aws_cmd eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${nodegroup}" \
    --query 'nodegroup.status' --output text 2>/dev/null || true
}

ensure_cluster_credentials() {
  aws eks update-kubeconfig \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --name "${CLUSTER_NAME}" \
    --alias "${KUBECONFIG_ALIAS}" >/dev/null
}

common_tags() {
  printf 'llmd.stack=inference-scheduling,llmd.provider=aws-agentgateway,llmd.cluster=%s,llmd.release=%s\n' \
    "${CLUSTER_NAME}" "${RELEASE_NAME_POSTFIX}"
}

sanitize_az() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//'
}

gpu_nodegroup_name_for_az() {
  local az="$1"
  printf '%s-%s\n' "${GPU_NODEGROUP_PREFIX}" "$(sanitize_az "${az}")"
}

gpu_capacity_reservation_name_for_az() {
  local az="$1"
  printf '%s-%s\n' "${ODCR_PREFIX}" "$(sanitize_az "${az}")"
}

discover_candidate_azs() {
  aws_cmd ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=${GPU_INSTANCE_TYPE}" \
    --query 'InstanceTypeOfferings[].Location' \
    --output text | tr '\t' '\n' | sed '/^$/d' | sort -u
}

effective_candidate_azs() {
  if [[ -n "${GPU_CANDIDATE_AZS}" ]]; then
    tr ',' '\n' <<<"${GPU_CANDIDATE_AZS}" | sed '/^$/d'
  else
    discover_candidate_azs
  fi
}

effective_cluster_azs_csv() {
  effective_candidate_azs | paste -sd, -
}

gpu_candidate_specs() {
  local az
  while IFS= read -r az; do
    [[ -n "${az}" ]] || continue
    printf '%s|%s\n' "$(gpu_nodegroup_name_for_az "${az}")" "${az}"
  done < <(effective_candidate_azs)
}

capacity_reservation_tag_spec_for_az() {
  local az="$1"
  local name

  name="$(gpu_capacity_reservation_name_for_az "${az}")"
  printf 'ResourceType=capacity-reservation,Tags=[{Key=Name,Value=%s},{Key=llmd.stack,Value=inference-scheduling},{Key=llmd.provider,Value=aws-agentgateway},{Key=llmd.cluster,Value=%s},{Key=llmd.release,Value=%s},{Key=llmd.capacity-mode,Value=%s},{Key=llmd.az,Value=%s}]' \
    "${name}" "${CLUSTER_NAME}" "${RELEASE_NAME_POSTFIX}" "${GPU_CAPACITY_MODE}" "${az}"
}

cluster_capacity_reservation_ids() {
  local az="${1:-}"
  local states_csv="${2:-active,pending,cancelled}"
  local values=(
    "Name=instance-type,Values=${GPU_INSTANCE_TYPE}"
    "Name=state,Values=${states_csv}"
    "Name=tag:llmd.cluster,Values=${CLUSTER_NAME}"
    "Name=tag:llmd.capacity-mode,Values=odcr"
  )

  if [[ -n "${az}" ]]; then
    values+=("Name=availability-zone,Values=${az}")
  fi

  aws_cmd ec2 describe-capacity-reservations \
    --filters "${values[@]}" \
    --query 'CapacityReservations[].CapacityReservationId' \
    --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d'
}

capacity_reservation_field() {
  local reservation_id="$1"
  local query="$2"

  aws_cmd ec2 describe-capacity-reservations \
    --capacity-reservation-ids "${reservation_id}" \
    --query "CapacityReservations[0].${query}" \
    --output text 2>/dev/null || true
}

capacity_reservation_state() {
  capacity_reservation_field "$1" "State"
}

capacity_reservation_available_instance_count() {
  capacity_reservation_field "$1" "AvailableInstanceCount"
}

capacity_reservation_instance_count() {
  capacity_reservation_field "$1" "TotalInstanceCount"
}

capacity_reservation_az() {
  capacity_reservation_field "$1" "AvailabilityZone"
}

cancel_capacity_reservation_if_present() {
  local reservation_id="$1"
  local state

  [[ -n "${reservation_id}" ]] || return 0

  state="$(capacity_reservation_state "${reservation_id}")"
  case "${state}" in
    active|pending|assessing)
      aws_cmd ec2 cancel-capacity-reservation --capacity-reservation-id "${reservation_id}" >/dev/null
      log_info "Cancelled capacity reservation ${reservation_id}."
      ;;
    cancelled|expired|"")
      ;;
    *)
      log_warn "Skipping cancellation for capacity reservation ${reservation_id} in state ${state}."
      ;;
  esac
}

cleanup_cluster_capacity_reservations() {
  local reservation_id

  while IFS= read -r reservation_id; do
    [[ -n "${reservation_id}" ]] || continue
    cancel_capacity_reservation_if_present "${reservation_id}"
  done < <(cluster_capacity_reservation_ids)
}

wait_for_capacity_reservation_state() {
  local reservation_id="$1"
  local desired_state="$2"
  local timeout="${3:-900}"
  local deadline state

  deadline=$(( $(date +%s) + timeout ))
  while true; do
    state="$(capacity_reservation_state "${reservation_id}")"
    if [[ "${state}" == "${desired_state}" ]]; then
      return 0
    fi

    case "${state}" in
      cancelled|expired)
        fail "Capacity reservation ${reservation_id} entered terminal state ${state}."
        ;;
    esac

    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for capacity reservation ${reservation_id} to reach ${desired_state}; current=${state:-<unknown>}."
    fi
    sleep 10
  done
}

current_node_count() {
  local nodegroup="$1"
  kubectl get nodes -l "eks.amazonaws.com/nodegroup=${nodegroup}" --no-headers 2>/dev/null | awk 'END { print NR+0 }'
}

ready_node_count() {
  local nodegroup="$1"
  kubectl get nodes -l "eks.amazonaws.com/nodegroup=${nodegroup}" --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ { count++ } END { print count+0 }'
}

active_gpu_nodegroup() {
  local spec nodegroup ready best_nodegroup best_ready
  best_ready=0
  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    IFS='|' read -r nodegroup _ <<<"${spec}"
    ready="$(ready_node_count "${nodegroup}")"
    if (( ready > best_ready )); then
      best_ready="${ready}"
      best_nodegroup="${nodegroup}"
    fi
  done < <(gpu_candidate_specs)
  if (( best_ready > 0 )); then
    printf '%s\n' "${best_nodegroup}"
  fi
}

required_gpu_nodes_for_decode_replicas() {
  local total_decode_replicas="$1"
  local total_gpus

  if (( total_decode_replicas <= 0 )); then
    printf '0\n'
    return 0
  fi

  total_gpus=$(( total_decode_replicas * DECODE_GPUS_PER_REPLICA ))
  printf '%s\n' "$(( (total_gpus + GPU_GPUS_PER_NODE - 1) / GPU_GPUS_PER_NODE ))"
}

wait_for_nodegroup_status() {
  local nodegroup="$1"
  local desired_status="$2"
  local timeout="${3:-3600}"
  local deadline status

  deadline=$(( $(date +%s) + timeout ))
  while true; do
    status="$(nodegroup_status "${nodegroup}")"
    if [[ "${status}" == "${desired_status}" ]]; then
      return 0
    fi
    case "${status}" in
      CREATE_FAILED|DELETE_FAILED|DEGRADED)
        fail "Nodegroup ${nodegroup} entered status ${status}."
        ;;
    esac
    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for nodegroup ${nodegroup} to reach status ${desired_status}; current=${status:-<unknown>}."
    fi
    sleep 15
  done
}

wait_for_ready_node_count() {
  local nodegroup="$1"
  local target="$2"
  local timeout="${3:-3600}"
  local deadline current

  deadline=$(( $(date +%s) + timeout ))
  while true; do
    current="$(ready_node_count "${nodegroup}")"
    if (( current >= target )); then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for nodegroup ${nodegroup} to reach ${target} ready node(s); current=${current}."
    fi
    sleep 15
  done
}

create_system_nodegroup() {
  if nodegroup_exists "${SYSTEM_NODEGROUP}"; then
    log_info "System nodegroup ${SYSTEM_NODEGROUP} already exists."
    return 0
  fi

  eksctl_cmd create nodegroup \
    --cluster "${CLUSTER_NAME}" \
    --name "${SYSTEM_NODEGROUP}" \
    --managed \
    --node-type "${SYSTEM_INSTANCE_TYPE}" \
    --nodes "${SYSTEM_NODE_COUNT}" \
    --nodes-min "${SYSTEM_NODE_COUNT}" \
    --nodes-max "${SYSTEM_NODE_COUNT}" \
    --node-volume-size "${SYSTEM_NODE_VOLUME_SIZE_GB}" \
    --node-volume-type gp3 \
    --tags "$(common_tags)"
  wait_for_nodegroup_status "${SYSTEM_NODEGROUP}" ACTIVE 3600
  log_success "Created system nodegroup ${SYSTEM_NODEGROUP}."
}

create_gpu_nodegroup() {
  local nodegroup="$1"
  local az="$2"

  if nodegroup_exists "${nodegroup}"; then
    log_info "GPU nodegroup ${nodegroup} already exists."
    return 0
  fi

  eksctl_cmd create nodegroup \
    --cluster "${CLUSTER_NAME}" \
    --name "${nodegroup}" \
    --managed \
    --node-type "${GPU_INSTANCE_TYPE}" \
    --nodes 0 \
    --nodes-min 0 \
    --nodes-max "${GPU_MAX_NODES}" \
    --node-volume-size "${GPU_NODE_VOLUME_SIZE_GB}" \
    --node-volume-type gp3 \
    --node-zones "${az}" \
    --install-nvidia-plugin \
    --node-ami-family AmazonLinux2023 \
    --node-labels "llmd.aws.gpu-node=true,llmd.aws.az=${az},llmd.aws.capacity-mode=${GPU_CAPACITY_MODE}" \
    --tags "$(common_tags),llmd.az=${az},llmd.nodegroup=${nodegroup},llmd.capacity-mode=${GPU_CAPACITY_MODE}"
  wait_for_nodegroup_status "${nodegroup}" ACTIVE 3600
  log_success "Created GPU nodegroup ${nodegroup} in ${az}."
}

ensure_gpu_candidate_nodegroups() {
  local spec nodegroup az
  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    IFS='|' read -r nodegroup az <<<"${spec}"
    create_gpu_nodegroup "${nodegroup}" "${az}"
  done < <(gpu_candidate_specs)
}

set_nodegroup_scale() {
  local nodegroup="$1"
  local desired="$2"
  local min_size="${3:-0}"
  local max_size="${4:-${GPU_MAX_NODES}}"

  aws_cmd eks update-nodegroup-config \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${nodegroup}" \
    --scaling-config "minSize=${min_size},maxSize=${max_size},desiredSize=${desired}" >/dev/null
}

ensure_system_nodes() {
  local target="${1:-1}"
  set_nodegroup_scale "${SYSTEM_NODEGROUP}" "${target}" "${target}" "${target}"
  wait_for_ready_node_count "${SYSTEM_NODEGROUP}" "${target}" 1800
}

deployment_replica_count() {
  local ns="$1"
  local name="$2"
  kubectl get deployment "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true
}

namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

ensure_namespace() {
  local ns="$1"
  if namespace_exists "${ns}"; then
    log_info "Namespace ${ns} already exists."
  else
    kubectl create namespace "${ns}" >/dev/null
    log_success "Created namespace ${ns}."
  fi
}

helm_release_exists() {
  local release="$1"
  local ns="$2"
  helm status "${release}" -n "${ns}" >/dev/null 2>&1
}

deployment_exists() {
  local name="$1"
  local ns="$2"
  kubectl get deployment "${name}" -n "${ns}" >/dev/null 2>&1
}

service_exists() {
  local name="$1"
  local ns="$2"
  kubectl get service "${name}" -n "${ns}" >/dev/null 2>&1
}

pod_exists() {
  local name="$1"
  local ns="$2"
  kubectl get pod "${name}" -n "${ns}" >/dev/null 2>&1
}

pod_phase() {
  local name="$1"
  local ns="$2"
  kubectl get pod "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

wait_for_deployment_replicas() {
  local ns="$1"
  local name="$2"
  local desired="$3"
  local timeout="${4:-1800}"
  local deadline spec updated ready available

  deadline=$(( $(date +%s) + timeout ))
  while true; do
    spec="$(kubectl get deployment "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    updated="$(kubectl get deployment "${name}" -n "${ns}" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)"
    ready="$(kubectl get deployment "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    available="$(kubectl get deployment "${name}" -n "${ns}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"

    spec="${spec:-0}"
    updated="${updated:-0}"
    ready="${ready:-0}"
    available="${available:-0}"

    if [[ "${spec}" == "${desired}" && "${updated}" == "${desired}" && "${ready}" == "${desired}" && "${available}" == "${desired}" ]]; then
      return 0
    fi

    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for deployment ${ns}/${name} to reach replicas=${desired}; spec=${spec} updated=${updated} ready=${ready} available=${available}."
    fi
    sleep 10
  done
}

wait_for_rollout() {
  local ns="$1"
  local name="$2"
  local desired="$3"
  local timeout="${4:-1800}"

  kubectl rollout status "deployment/${name}" -n "${ns}" --timeout="${timeout}s" >/dev/null
  wait_for_deployment_replicas "${ns}" "${name}" "${desired}" "${timeout}"
}

wait_for_pod_ready() {
  local ns="$1"
  local name="$2"
  local timeout="${3:-600}"
  kubectl wait --for=condition=Ready "pod/${name}" -n "${ns}" --timeout="${timeout}s" >/dev/null
}

wait_for_gateway_programmed() {
  local timeout="${1:-900}"
  kubectl wait --for=condition=Programmed "gateway/${GATEWAY_NAME}" -n "${NAMESPACE}" --timeout="${timeout}s" >/dev/null
}

wait_for_httproute_ready() {
  local timeout="${1:-900}"
  kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True "httproute/${HTTPROUTE_NAME}" -n "${NAMESPACE}" --timeout="${timeout}s" >/dev/null
  kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'=True "httproute/${HTTPROUTE_NAME}" -n "${NAMESPACE}" --timeout="${timeout}s" >/dev/null
}

apply_httproute() {
  local tmp
  tmp="$(mktemp)"
  sed \
    -e "s/infra-inference-scheduling-inference-gateway/${GATEWAY_NAME}/g" \
    -e "s/gaie-inference-scheduling/${GAIE_RELEASE}/g" \
    "${GUIDE_DIR}/httproute.yaml" > "${tmp}"
  kubectl apply -f "${tmp}" -n "${NAMESPACE}" >/dev/null
  rm -f "${tmp}"
}

delete_httproute() {
  kubectl delete httproute "${HTTPROUTE_NAME}" -n "${NAMESPACE}" --ignore-not-found >/dev/null
}

render_ms_values_overlay() {
  local replicas="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<EOF
decode:
  replicas: ${replicas}
  nodeSelector:
    llmd.aws.gpu-node: "true"
EOF
  printf '%s\n' "${tmp}"
}

resolve_hf_token() {
  if [[ -n "${HF_TOKEN:-}" ]]; then
    printf '%s\n' "${HF_TOKEN}"
    return 0
  fi

  if [[ -f "${HOME}/.cache/huggingface/token" ]]; then
    tr -d '\n' < "${HOME}/.cache/huggingface/token"
    return 0
  fi

  return 1
}

ensure_hf_secret() {
  if kubectl get secret "${HF_SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Secret ${NAMESPACE}/${HF_SECRET_NAME} already exists."
    return 0
  fi

  local token
  token="$(resolve_hf_token)" || fail "Could not resolve a Hugging Face token. Set HF_TOKEN or create ${HF_SECRET_NAME} in namespace ${NAMESPACE}."
  kubectl create secret generic "${HF_SECRET_NAME}" \
    -n "${NAMESPACE}" \
    --from-literal=HF_TOKEN="${token}" >/dev/null
  log_success "Created secret ${NAMESPACE}/${HF_SECRET_NAME}."
}

ensure_smoke_client() {
  local ns="$1"
  local name="$2"
  local image="$3"
  local timeout="${4:-600}"
  local phase

  if pod_exists "${name}" "${ns}"; then
    phase="$(pod_phase "${name}" "${ns}")"
    case "${phase}" in
      Running)
        wait_for_pod_ready "${ns}" "${name}" "${timeout}"
        log_info "Smoke client ${ns}/${name} already exists."
        return 0
        ;;
      Pending)
        wait_for_pod_ready "${ns}" "${name}" "${timeout}"
        log_info "Smoke client ${ns}/${name} became ready."
        return 0
        ;;
      *)
        kubectl delete pod "${name}" -n "${ns}" --ignore-not-found >/dev/null
        ;;
    esac
  fi

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/name: smoke-client
    app.kubernetes.io/component: smoke-test
spec:
  restartPolicy: Always
  containers:
    - name: curl
      image: ${image}
      command:
        - sh
        - -c
        - sleep 365d
EOF

  wait_for_pod_ready "${ns}" "${name}" "${timeout}"
  log_success "Smoke client ${ns}/${name} is ready."
}

delete_smoke_client() {
  local ns="$1"
  local name="$2"
  kubectl delete pod "${name}" -n "${ns}" --ignore-not-found >/dev/null
}

scale_deployment() {
  local ns="$1"
  local name="$2"
  local replicas="$3"
  local timeout="${4:-3600}"

  deployment_exists "${name}" "${ns}" || fail "Deployment ${ns}/${name} does not exist."
  kubectl scale "deployment/${name}" -n "${ns}" --replicas="${replicas}" >/dev/null
  wait_for_rollout "${ns}" "${name}" "${replicas}" "${timeout}"
  log_success "Scaled ${ns}/${name} to ${replicas} replica(s)."
}

print_status_block() {
  local title="$1"
  shift
  printf '\n%s\n' "${title}"
  "$@"
}
