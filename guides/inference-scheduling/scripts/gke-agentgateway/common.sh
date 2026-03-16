#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../../.." && pwd)"
GUIDE_DIR="${REPO_ROOT}/guides/inference-scheduling"
GATEWAY_DIR="${REPO_ROOT}/guides/prereq/gateway-provider"
MONITORING_SCRIPT="${REPO_ROOT}/docs/monitoring/scripts/install-prometheus-grafana.sh"

PROJECT_ID="${PROJECT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-llmd-agw-is-c1}"
CLUSTER_ZONE="${CLUSTER_ZONE:-us-central1-f}"
NODE_LOCATION="${NODE_LOCATION:-us-central1-b}"
CLUSTER_VERSION="${CLUSTER_VERSION:-}"
DEFAULT_NODEPOOL="${DEFAULT_NODEPOOL:-default-pool}"
DEFAULT_NODE_COUNT="${DEFAULT_NODE_COUNT:-1}"
DEFAULT_MACHINE_TYPE="${DEFAULT_MACHINE_TYPE:-e2-standard-4}"
H100_CAPACITY_MODE="${H100_CAPACITY_MODE:-queued}"
H100_NODEPOOL="${H100_NODEPOOL:-a3-queued-pool}"
H100_MACHINE_TYPE="${H100_MACHINE_TYPE:-a3-highgpu-2g}"
H100_GPU_TYPE="${H100_GPU_TYPE:-nvidia-h100-80gb}"
H100_GPUS_PER_NODE="${H100_GPUS_PER_NODE:-2}"
H100_MAX_NODES="${H100_MAX_NODES:-8}"
H100_DISK_SIZE_GB="${H100_DISK_SIZE_GB:-1000}"
H100_RESERVED_NODEPOOL="${H100_RESERVED_NODEPOOL:-a3-reserved-pool}"
H100_RESERVED_ZONE="${H100_RESERVED_ZONE:-${NODE_LOCATION}}"
H100_RESERVED_MACHINE_TYPE="${H100_RESERVED_MACHINE_TYPE:-a3-highgpu-8g}"
H100_RESERVED_GPU_TYPE="${H100_RESERVED_GPU_TYPE:-${H100_GPU_TYPE}}"
H100_RESERVED_GPUS_PER_NODE="${H100_RESERVED_GPUS_PER_NODE:-8}"
H100_RESERVED_MAX_NODES="${H100_RESERVED_MAX_NODES:-2}"
H100_RESERVED_RESERVATION_NAME="${H100_RESERVED_RESERVATION_NAME:-llmd-h100-reservation}"
H100_FUTURE_RESERVATION_NAME="${H100_FUTURE_RESERVATION_NAME:-llmd-h100-future}"
H100_FUTURE_RESERVATION_REGION="${H100_FUTURE_RESERVATION_REGION:-}"
H100_FUTURE_RESERVATION_VM_COUNT="${H100_FUTURE_RESERVATION_VM_COUNT:-2}"
DECODE_GPUS_PER_REPLICA="${DECODE_GPUS_PER_REPLICA:-2}"
QUEUE_CANDIDATES="${QUEUE_CANDIDATES:-}"
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

require_project_id() {
  [[ -n "${PROJECT_ID}" ]] || fail "Set PROJECT_ID before running this script."
}

active_gcloud_account() {
  gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1
}

capacity_mode_is_queued() {
  [[ "${H100_CAPACITY_MODE}" == "queued" ]]
}

capacity_mode_is_reservation() {
  [[ "${H100_CAPACITY_MODE}" == "reservation" ]]
}

ensure_supported_capacity_mode() {
  case "${H100_CAPACITY_MODE}" in
    queued|reservation)
      ;;
    *)
      fail "Unsupported H100_CAPACITY_MODE=${H100_CAPACITY_MODE}. Use queued or reservation."
      ;;
  esac
}

region_from_zone() {
  local zone="$1"
  printf '%s\n' "${zone%-*}"
}

reservation_region() {
  if [[ -n "${H100_FUTURE_RESERVATION_REGION}" ]]; then
    printf '%s\n' "${H100_FUTURE_RESERVATION_REGION}"
  else
    region_from_zone "${H100_RESERVED_ZONE}"
  fi
}

normalize_duration_seconds() {
  local raw="$1"

  [[ -n "${raw}" ]] || fail "normalize_duration_seconds requires a duration value."

  python3 - "${raw}" <<'PY'
import re
import sys

value = sys.argv[1].strip().lower()
match = re.fullmatch(r'(\d+)([smhd]?)', value)
if not match:
    raise SystemExit(1)

amount = int(match.group(1))
unit = match.group(2) or "s"
multiplier = {
    "s": 1,
    "m": 60,
    "h": 3600,
    "d": 86400,
}[unit]
print(amount * multiplier)
PY
}

test_project_permissions() {
  local access_token payload
  local perms=("$@")

  ((${#perms[@]} > 0)) || fail "test_project_permissions requires at least one permission."

  access_token="$(gcloud auth print-access-token)"
  payload="$(
    python3 - "${perms[@]}" <<'PY'
import json
import sys

print(json.dumps({"permissions": sys.argv[1:]}))
PY
  )"

  curl -fsS \
    -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" \
    -d "${payload}" | python3 - "${perms[@]}" <<'PY'
import json
import sys

requested = sys.argv[1:]
response = json.load(sys.stdin)
granted = set(response.get("permissions", []))

for permission in requested:
    if permission not in granted:
        print(permission)
PY
}

require_project_permissions() {
  local missing
  local account
  local missing_joined

  missing="$(test_project_permissions "$@")" || fail "Unable to test IAM permissions for project ${PROJECT_ID}."
  if [[ -n "${missing}" ]]; then
    account="$(active_gcloud_account)"
    [[ -n "${account}" ]] || account="<unknown>"
    missing_joined="$(printf '%s\n' "${missing}" | paste -sd ',' - | sed 's/,/, /g')"
    fail "Active gcloud account ${account} is missing required project permission(s): ${missing_joined}."
  fi
}

cluster_exists() {
  gcloud container clusters describe "${CLUSTER_NAME}" \
    --zone "${CLUSTER_ZONE}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1
}

nodepool_exists() {
  local nodepool="$1"
  gcloud container node-pools describe "${nodepool}" \
    --cluster "${CLUSTER_NAME}" \
    --zone "${CLUSTER_ZONE}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1
}

reservation_exists() {
  gcloud compute reservations describe "${H100_RESERVED_RESERVATION_NAME}" \
    --zone "${H100_RESERVED_ZONE}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1
}

queue_candidate_specs() {
  local specs
  local IFS=';'

  if [[ -n "${QUEUE_CANDIDATES}" ]]; then
    read -r -a specs <<<"${QUEUE_CANDIDATES}"
  else
    specs=("${H100_NODEPOOL}|${NODE_LOCATION}|${H100_MACHINE_TYPE}|${H100_GPU_TYPE}|${H100_GPUS_PER_NODE}|${H100_MAX_NODES}")
  fi

  printf '%s\n' "${specs[@]}"
}

parse_queue_candidate() {
  local spec="$1"
  local default_max_nodes="${H100_MAX_NODES}"
  IFS='|' read -r CANDIDATE_POOL CANDIDATE_ZONE CANDIDATE_MACHINE_TYPE CANDIDATE_GPU_TYPE CANDIDATE_GPU_COUNT CANDIDATE_MAX_NODES <<<"${spec}"
  CANDIDATE_MAX_NODES="${CANDIDATE_MAX_NODES:-${default_max_nodes}}"
  [[ -n "${CANDIDATE_POOL}" && -n "${CANDIDATE_ZONE}" && -n "${CANDIDATE_MACHINE_TYPE}" && -n "${CANDIDATE_GPU_TYPE}" && -n "${CANDIDATE_GPU_COUNT}" ]] || \
    fail "Invalid queue candidate spec: ${spec}. Expected pool|zone|machine_type|gpu_type|gpu_count|optional_max_nodes."
}

ensure_queue_candidate_pool() {
  local spec="$1"
  parse_queue_candidate "${spec}"

  if nodepool_exists "${CANDIDATE_POOL}"; then
    log_info "Queued pool ${CANDIDATE_POOL} already exists."
    return 0
  fi

  gcloud container node-pools create "${CANDIDATE_POOL}" \
    --cluster "${CLUSTER_NAME}" \
    --zone "${CLUSTER_ZONE}" \
    --project "${PROJECT_ID}" \
    --enable-queued-provisioning \
    --accelerator "type=${CANDIDATE_GPU_TYPE},count=${CANDIDATE_GPU_COUNT},gpu-driver-version=default" \
    --machine-type "${CANDIDATE_MACHINE_TYPE}" \
    --flex-start \
    --enable-autoscaling \
    --num-nodes 0 \
    --total-min-nodes 0 \
    --total-max-nodes "${CANDIDATE_MAX_NODES}" \
    --location-policy ANY \
    --reservation-affinity none \
    --node-locations "${CANDIDATE_ZONE}" \
    --disk-size "${H100_DISK_SIZE_GB}" \
    --disk-type pd-balanced \
    --no-enable-autorepair
  log_success "Created queued pool ${CANDIDATE_POOL} in ${CANDIDATE_ZONE}."
}

ensure_queue_candidate_pools() {
  local spec
  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    ensure_queue_candidate_pool "${spec}"
  done < <(queue_candidate_specs)
}

ensure_reserved_pool() {
  if nodepool_exists "${H100_RESERVED_NODEPOOL}"; then
    log_info "Reservation-backed pool ${H100_RESERVED_NODEPOOL} already exists."
    return 0
  fi

  [[ -n "${H100_RESERVED_RESERVATION_NAME}" ]] || fail "Set H100_RESERVED_RESERVATION_NAME before creating a reservation-backed pool."
  reservation_exists || fail "Reservation ${H100_RESERVED_RESERVATION_NAME} is not active in ${H100_RESERVED_ZONE}. Create and activate the future reservation first, then retry ensure-reserved."

  gcloud container node-pools create "${H100_RESERVED_NODEPOOL}" \
    --cluster "${CLUSTER_NAME}" \
    --zone "${CLUSTER_ZONE}" \
    --project "${PROJECT_ID}" \
    --enable-autoscaling \
    --num-nodes 0 \
    --total-min-nodes 0 \
    --total-max-nodes "${H100_RESERVED_MAX_NODES}" \
    --location-policy ANY \
    --accelerator "type=${H100_RESERVED_GPU_TYPE},count=${H100_RESERVED_GPUS_PER_NODE},gpu-driver-version=default" \
    --machine-type "${H100_RESERVED_MACHINE_TYPE}" \
    --reservation-affinity specific \
    --reservation "${H100_RESERVED_RESERVATION_NAME}" \
    --node-locations "${H100_RESERVED_ZONE}" \
    --disk-size "${H100_DISK_SIZE_GB}" \
    --disk-type pd-balanced
  log_success "Created reservation-backed pool ${H100_RESERVED_NODEPOOL} in ${H100_RESERVED_ZONE}."
}

ensure_h100_capacity_pools() {
  ensure_supported_capacity_mode
  if capacity_mode_is_queued; then
    ensure_queue_candidate_pools
  else
    ensure_reserved_pool
  fi
}

ensure_cluster_credentials() {
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --zone "${CLUSTER_ZONE}" \
    --project "${PROJECT_ID}" >/dev/null
}

current_node_count() {
  local nodepool="$1"
  kubectl get nodes -l "cloud.google.com/gke-nodepool=${nodepool}" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

ready_node_count() {
  local nodepool="$1"
  kubectl get nodes -l "cloud.google.com/gke-nodepool=${nodepool}" --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ { count++ } END { print count+0 }'
}

required_h100_nodes_for_decode_replicas() {
  local replica_delta="$1"
  local gpus_per_node
  local total_gpus

  if (( replica_delta <= 0 )); then
    printf '0\n'
    return 0
  fi

  if capacity_mode_is_reservation; then
    gpus_per_node="${H100_RESERVED_GPUS_PER_NODE}"
  else
    gpus_per_node="${H100_GPUS_PER_NODE}"
  fi

  total_gpus=$(( replica_delta * DECODE_GPUS_PER_REPLICA ))
  printf '%s\n' "$(( (total_gpus + gpus_per_node - 1) / gpus_per_node ))"
}

active_h100_nodepool() {
  if capacity_mode_is_reservation; then
    printf '%s\n' "${H100_RESERVED_NODEPOOL}"
  else
    printf '%s\n' "${H100_NODEPOOL}"
  fi
}

deployment_replica_count() {
  local ns="$1"
  local name="$2"
  kubectl get deployment "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true
}

wait_for_node_count() {
  local nodepool="$1"
  local target="$2"
  local timeout="${3:-900}"
  local deadline
  local current

  deadline=$(( $(date +%s) + timeout ))
  while true; do
    current="$(current_node_count "${nodepool}")"
    if [[ "${current}" == "${target}" ]]; then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for nodepool ${nodepool} to reach ${target} nodes; current=${current}."
    fi
    sleep 10
  done
}

wait_for_ready_node_count() {
  local nodepool="$1"
  local target="$2"
  local timeout="${3:-1800}"
  local deadline
  local current

  deadline=$(( $(date +%s) + timeout ))
  while true; do
    current="$(ready_node_count "${nodepool}")"
    if (( current >= target )); then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for nodepool ${nodepool} to reach ${target} ready node(s); current=${current}."
    fi
    sleep 10
  done
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

provisioning_request_exists() {
  local ns="$1"
  local name="$2"
  kubectl get provisioningrequest "${name}" -n "${ns}" >/dev/null 2>&1
}

provisioning_request_condition_status() {
  local ns="$1"
  local name="$2"
  local type="$3"
  kubectl get provisioningrequest "${name}" -n "${ns}" -o jsonpath="{.status.conditions[?(@.type==\"${type}\")].status}" 2>/dev/null || true
}

provisioning_request_pod_count() {
  local ns="$1"
  local name="$2"
  kubectl get provisioningrequest "${name}" -n "${ns}" -o jsonpath='{.spec.podSets[0].count}' 2>/dev/null || true
}

require_active_capacity_request() {
  local ns="$1"
  local name="$2"
  local required_count="${3:-0}"
  local accepted
  local provisioned
  local booking_expired
  local request_count

  provisioning_request_exists "${ns}" "${name}" || fail "ProvisioningRequest ${ns}/${name} does not exist."

  accepted="$(provisioning_request_condition_status "${ns}" "${name}" "Accepted")"
  provisioned="$(provisioning_request_condition_status "${ns}" "${name}" "Provisioned")"
  booking_expired="$(provisioning_request_condition_status "${ns}" "${name}" "BookingExpired")"
  request_count="$(provisioning_request_pod_count "${ns}" "${name}")"

  [[ "${accepted}" == "True" ]] || fail "ProvisioningRequest ${ns}/${name} is not Accepted."
  [[ "${provisioned}" == "True" ]] || fail "ProvisioningRequest ${ns}/${name} is not Provisioned."
  [[ "${booking_expired}" != "True" ]] || fail "ProvisioningRequest ${ns}/${name} booking has expired."

  if [[ -n "${required_count}" && "${required_count}" != "0" ]]; then
    [[ -n "${request_count}" ]] || fail "ProvisioningRequest ${ns}/${name} does not report a podSets count."
    if (( request_count < required_count )); then
      fail "ProvisioningRequest ${ns}/${name} only covers ${request_count} pod(s), but ${required_count} additional pod(s) are required."
    fi
  fi
}

wait_for_deployment_replicas() {
  local ns="$1"
  local name="$2"
  local desired="$3"
  local timeout="${4:-1800}"
  local deadline
  local spec
  local updated
  local ready
  local available

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
  tolerations:
    - key: cloud.google.com/gke-queued
      operator: Equal
      value: "true"
      effect: NoSchedule
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

ensure_default_pool_nodes() {
  local target="${1:-1}"
  local current

  current="$(current_node_count "${DEFAULT_NODEPOOL}")"
  if (( current >= target )); then
    log_info "Default node pool already has ${current} node(s)."
    return 0
  fi

  log_info "Resizing ${DEFAULT_NODEPOOL} to ${target} node(s)."
  gcloud container clusters resize "${CLUSTER_NAME}" \
    --node-pool "${DEFAULT_NODEPOOL}" \
    --zone "${CLUSTER_ZONE}" \
    --project "${PROJECT_ID}" \
    --num-nodes "${target}" \
    --quiet >/dev/null
  wait_for_node_count "${DEFAULT_NODEPOOL}" "${target}" 1800
  log_success "${DEFAULT_NODEPOOL} now has ${target} node(s)."
}

ensure_idle_namespace() {
  local ns="$1"
  local count

  if ! namespace_exists "${ns}"; then
    return 0
  fi

  count="$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | awk '$3 != "Completed" && $3 != "Succeeded" { count++ } END { print count+0 }')"
  if [[ "${count}" != "0" ]]; then
    fail "Namespace ${ns} still has ${count} non-completed pod(s). Remove the workload before scaling ${DEFAULT_NODEPOOL} to zero."
  fi
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
