#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
BENCHMARK_DIR="${REPO_ROOT}/guides/benchmark"

NAMESPACE="${NAMESPACE:-}"
BENCHMARK_NAMESPACE="${BENCHMARK_NAMESPACE:-${NAMESPACE:-}}"
STACK_TYPE="${STACK_TYPE:-}"
BENCHMARK_PROFILE="${BENCHMARK_PROFILE:-default}"
RELEASE_NAME_POSTFIX="${RELEASE_NAME_POSTFIX:-}"
GATEWAY_NAME="${GATEWAY_NAME:-}"
GATEWAY_SVC="${GATEWAY_SVC:-}"
BENCHMARK_TEMPLATE="${BENCHMARK_TEMPLATE:-}"
BENCHMARK_PVC="${BENCHMARK_PVC:-llmd-benchmark-results}"
BENCHMARK_STORAGE_CLASS="${BENCHMARK_STORAGE_CLASS:-standard-rwx}"
BENCHMARK_PVC_SIZE="${BENCHMARK_PVC_SIZE:-200Gi}"
BENCHMARK_CONFIG_PATH="${BENCHMARK_CONFIG_PATH:-${TMPDIR:-/tmp}/llmd-benchmark-config.yaml}"
RUN_ONLY_URL="${RUN_ONLY_URL:-https://raw.githubusercontent.com/llm-d/llm-d-benchmark/main/existing_stack/run_only.sh}"
RUN_ONLY_PATH="${RUN_ONLY_PATH:-${TMPDIR:-/tmp}/llmd-benchmark-run_only.sh}"
HARNESS_POD_NAME_PATTERN="${HARNESS_POD_NAME_PATTERN:-llmdbench-.*-launcher}"
BENCHMARK_COMPAT_BIN_DIR="${BENCHMARK_COMPAT_BIN_DIR:-${TMPDIR:-/tmp}/llmd-benchmark-bin}"
BENCHMARK_HARNESS_CPU="${BENCHMARK_HARNESS_CPU:-}"
BENCHMARK_HARNESS_MEMORY="${BENCHMARK_HARNESS_MEMORY:-}"

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

require_namespace() {
  [[ -n "${NAMESPACE}" ]] || fail "Set NAMESPACE before running this script."
}

require_stack_type() {
  [[ -n "${STACK_TYPE}" ]] || fail "Set STACK_TYPE to one of: inference-scheduling, precise, pd-disaggregation, wva-inference-scheduling. Wide EP benchmark support is tracked in #974."
}

namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

service_exists() {
  local name="$1"
  local ns="$2"
  kubectl get service "${name}" -n "${ns}" >/dev/null 2>&1
}

pvc_exists() {
  local name="$1"
  local ns="$2"
  kubectl get pvc "${name}" -n "${ns}" >/dev/null 2>&1
}

storage_class_exists() {
  kubectl get storageclass "$1" >/dev/null 2>&1
}

benchmark_pvc_phase() {
  local ns="$1"
  local name="$2"

  kubectl get pvc "${name}" -n "${ns}" -o jsonpath='{.status.phase}'
}

benchmark_pvc_warning_events() {
  local ns="$1"
  local name="$2"

  kubectl describe pvc "${name}" -n "${ns}" | awk '
    /^Events:/ {events=1; next}
    events && /^  Type/ {next}
    events && /^  ----/ {next}
    events && NF == 0 {next}
    events && $1 == "Warning" {$1=""; sub(/^ +/, ""); print}
  '
}

check_benchmark_pvc() {
  local ns="$1"
  local name="$2"
  local storage_class="$3"
  local phase
  local warnings

  storage_class_exists "${storage_class}" || fail "StorageClass ${storage_class} does not exist. Set BENCHMARK_STORAGE_CLASS to an RWX-capable class before running the benchmark."
  pvc_exists "${name}" "${ns}" || fail "Benchmark PVC ${ns}/${name} does not exist. Run ensure-pvc first."

  phase="$(benchmark_pvc_phase "${ns}" "${name}")"
  case "${phase}" in
    Bound)
      log_success "Benchmark PVC ${ns}/${name} is Bound."
      return 0
      ;;
    Pending)
      warnings="$(benchmark_pvc_warning_events "${ns}" "${name}")"
      if [[ -n "${warnings}" ]]; then
        fail "$(printf 'Benchmark PVC %s/%s is Pending. Recent warning events:\n%s' "${ns}" "${name}" "${warnings}")"
      fi
      log_info "Benchmark PVC ${ns}/${name} is Pending with no warning events. This is usually expected for WaitForFirstConsumer storage classes and should bind once the harness pod schedules."
      return 0
      ;;
    Lost)
      fail "Benchmark PVC ${ns}/${name} is Lost. Recreate it before running the benchmark."
      ;;
    "")
      fail "Could not determine PVC phase for ${ns}/${name}."
      ;;
    *)
      fail "Benchmark PVC ${ns}/${name} is in unexpected phase ${phase}."
      ;;
  esac
}

default_release_name_postfix() {
  case "${STACK_TYPE}" in
    inference-scheduling)
      printf '%s\n' "inference-scheduling"
      ;;
    precise)
      printf '%s\n' "kv-events"
      ;;
    pd-disaggregation)
      printf '%s\n' "pd"
      ;;
    wva-inference-scheduling)
      printf '%s\n' "workload-autoscaler"
      ;;
    wide-ep-lws|wide-ep)
      fail "Wide EP benchmark support is not implemented yet. Tracking issue: #974."
      ;;
    *)
      fail "Unsupported STACK_TYPE ${STACK_TYPE}."
      ;;
  esac
}

resolved_release_name_postfix() {
  if [[ -n "${RELEASE_NAME_POSTFIX}" ]]; then
    printf '%s\n' "${RELEASE_NAME_POSTFIX}"
  else
    default_release_name_postfix
  fi
}

resolved_gateway_name() {
  if [[ -n "${GATEWAY_NAME}" ]]; then
    printf '%s\n' "${GATEWAY_NAME}"
    return 0
  fi

  case "${STACK_TYPE}" in
    inference-scheduling|precise|pd-disaggregation)
      printf 'infra-%s-inference-gateway\n' "$(resolved_release_name_postfix)"
      ;;
    wva-inference-scheduling)
      fail "Set GATEWAY_NAME explicitly for STACK_TYPE=wva-inference-scheduling."
      ;;
    wide-ep-lws|wide-ep)
      fail "Wide EP benchmark support is not implemented yet. Tracking issue: #974."
      ;;
    *)
      fail "Unsupported STACK_TYPE ${STACK_TYPE}."
      ;;
  esac
}

resolved_template_path() {
  local template_file

  if [[ -n "${BENCHMARK_TEMPLATE}" ]]; then
    if [[ -f "${BENCHMARK_TEMPLATE}" ]]; then
      printf '%s\n' "${BENCHMARK_TEMPLATE}"
      return 0
    fi
    fail "BENCHMARK_TEMPLATE does not exist: ${BENCHMARK_TEMPLATE}"
  fi

  case "${STACK_TYPE}:${BENCHMARK_PROFILE}" in
    inference-scheduling:default)
      template_file="inference_scheduling_template.yaml"
      ;;
    inference-scheduling:guidellm)
      template_file="inference_scheduling_guidellm_template.yaml"
      ;;
    inference-scheduling:guide)
      template_file="inference_scheduling_guide_template.yaml"
      ;;
    inference-scheduling:shared-prefix)
      template_file="inference_scheduling_shared_prefix_template.yaml"
      ;;
    precise:default)
      template_file="precise_template.yaml"
      ;;
    precise:guidellm)
      template_file="precise_guidellm_template.yaml"
      ;;
    precise:guide)
      template_file="precise_guide_template.yaml"
      ;;
    precise:shared-prefix)
      template_file="precise_shared_prefix_template.yaml"
      ;;
    pd-disaggregation:default)
      template_file="pd_template.yaml"
      ;;
    pd-disaggregation:shared-prefix)
      template_file="pd_shared_prefix_template.yaml"
      ;;
    wva-inference-scheduling:default|wva-inference-scheduling:guidellm)
      template_file="wva_inference_scheduling_guidellm_template.yaml"
      ;;
    wide-ep-lws:*|wide-ep:*)
      fail "Wide EP benchmark support is not implemented yet because the repo is missing guides/benchmark/wide_ep_template.yaml. Tracking issue: #974."
      ;;
    *)
      fail "Unsupported benchmark profile ${BENCHMARK_PROFILE} for STACK_TYPE ${STACK_TYPE}."
      ;;
  esac

  if [[ ! -f "${BENCHMARK_DIR}/${template_file}" ]]; then
    fail "Benchmark template is not available in this repo: ${BENCHMARK_DIR}/${template_file}"
  fi

  printf '%s\n' "${BENCHMARK_DIR}/${template_file}"
}

resolved_gateway_svc() {
  local gateway_name
  local svc

  if [[ -n "${GATEWAY_SVC}" ]]; then
    printf '%s\n' "${GATEWAY_SVC}"
    return 0
  fi

  gateway_name="$(resolved_gateway_name)"
  svc="$(kubectl get svc -n "${NAMESPACE}" \
    -l "gateway.networking.k8s.io/gateway-name=${gateway_name}" \
    --no-headers -o custom-columns=':metadata.name' | head -1)"

  [[ -n "${svc}" ]] || fail "Could not resolve a gateway service for gateway ${gateway_name} in namespace ${NAMESPACE}."
  printf '%s\n' "${svc}"
}

ensure_benchmark_pvc() {
  local ns="$1"
  local name="$2"
  local storage_class="$3"
  local size="$4"

  if pvc_exists "${name}" "${ns}"; then
    log_info "Benchmark PVC ${ns}/${name} already exists."
    return 0
  fi

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: ${size}
  storageClassName: ${storage_class}
EOF

  log_success "Created benchmark PVC ${ns}/${name} with storageClass=${storage_class}."
}

ensure_run_only() {
  local dir

  if [[ -x "${RUN_ONLY_PATH}" ]]; then
    log_info "Benchmark runner already exists at ${RUN_ONLY_PATH}."
  else
    dir="$(dirname "${RUN_ONLY_PATH}")"
    mkdir -p "${dir}"
    curl -fsSL "${RUN_ONLY_URL}" -o "${RUN_ONLY_PATH}"
    chmod u+x "${RUN_ONLY_PATH}"
    log_success "Downloaded benchmark runner to ${RUN_ONLY_PATH}."
  fi
  patch_run_only_for_env_overrides
}

patch_run_only_for_env_overrides() {
  python3 - "${RUN_ONLY_PATH}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

replacements = {
    "HARNESS_CPU_NR=16": 'HARNESS_CPU_NR=${HARNESS_CPU_NR:-16}',
    "HARNESS_CPU_MEM=32Gi": 'HARNESS_CPU_MEM=${HARNESS_CPU_MEM:-32Gi}',
}

for old, new in replacements.items():
    if old in text and new not in text:
        text = text.replace(old, new)

gpu_toggle_old = 'HARNESS_CPU_MEM=${HARNESS_CPU_MEM:-32Gi}\n'
gpu_toggle_new = gpu_toggle_old + 'HARNESS_TOLERATE_GPU_NODES=${HARNESS_TOLERATE_GPU_NODES:-false}\n'
if gpu_toggle_old in text and 'HARNESS_TOLERATE_GPU_NODES=${HARNESS_TOLERATE_GPU_NODES:-false}' not in text:
    text = text.replace(gpu_toggle_old, gpu_toggle_new, 1)

simple_pipeline = """  cat <<EOF | yq "${volume_def}" | yq '.spec.containers[0].env = load("'${_config_file}'").env + .spec.containers[0].env' | ${control_kubectl} apply -f -"""
broken_pipeline = """  cat <<EOF | yq "${volume_def}" | yq '.spec.containers[0].env = load("'${_config_file}'").env + .spec.containers[0].env' | yq 'if env(HARNESS_TOLERATE_GPU_NODES) == "true" then .spec.tolerations = ((.spec.tolerations // []) + [{"key":"nvidia.com/gpu","operator":"Equal","value":"present","effect":"NoSchedule"},{"key":"cloud.google.com/gke-queued","operator":"Equal","value":"true","effect":"NoSchedule"}]) else . end' | ${control_kubectl} apply -f -"""
if broken_pipeline in text:
    text = text.replace(broken_pipeline, simple_pipeline, 1)

tolerations_init_old = """  ${control_kubectl} --namespace ${harness_namespace} delete pod ${pod_name} --ignore-not-found

"""
tolerations_init_new = """  local tolerations_block=""
  if [[ "${HARNESS_TOLERATE_GPU_NODES}" == "true" ]]; then
    tolerations_block=$(cat <<'TOLERATIONS'
  tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: present
    effect: NoSchedule
  - key: cloud.google.com/gke-queued
    operator: Equal
    value: "true"
    effect: NoSchedule
TOLERATIONS
)
  fi

  ${control_kubectl} --namespace ${harness_namespace} delete pod ${pod_name} --ignore-not-found

"""
if tolerations_init_old in text and 'local tolerations_block=""' not in text:
    text = text.replace(tolerations_init_old, tolerations_init_new, 1)

svc_old = """  serviceAccountName: llmdbench-harness-sa
  containers:
"""
svc_broken = """  serviceAccountName: llmdbench-harness-sa
${tolerations_block}  containers:
"""
svc_new = """  serviceAccountName: llmdbench-harness-sa
${tolerations_block}
  containers:
"""
if svc_old in text and '${tolerations_block}' not in text:
    text = text.replace(svc_old, svc_new, 1)
if svc_broken in text:
    text = text.replace(svc_broken, svc_new, 1)

path.write_text(text)
PY

  chmod u+x "${RUN_ONLY_PATH}"
}

ensure_timeout_compat() {
  local compat_dir="${BENCHMARK_COMPAT_BIN_DIR}"

  if command -v timeout >/dev/null 2>&1; then
    printf '%s\n' ""
    return 0
  fi

  mkdir -p "${compat_dir}"

  if [[ -x "${compat_dir}/timeout" ]]; then
    printf '%s\n' "${compat_dir}"
    return 0
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    ln -sf "$(command -v gtimeout)" "${compat_dir}/timeout"
    printf '%s\n' "${compat_dir}"
    return 0
  fi

  cat > "${compat_dir}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: timeout <duration> <command> [args...]" >&2
  exit 125
fi

duration="$1"
shift

python3 - "$duration" "$@" <<'PY'
import os
import signal
import subprocess
import sys

def parse_duration(value: str) -> float:
    if value.endswith("s"):
        return float(value[:-1])
    return float(value)

timeout = parse_duration(sys.argv[1])
cmd = sys.argv[2:]

proc = subprocess.Popen(cmd)
try:
    sys.exit(proc.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    sys.exit(124)
PY
EOF
  chmod u+x "${compat_dir}/timeout"
  printf '%s\n' "${compat_dir}"
}

ensure_yq_shell_compat() {
  local compat_dir="${BENCHMARK_COMPAT_BIN_DIR}"
  local real_yq

  real_yq="$(command -v yq)"
  mkdir -p "${compat_dir}"

  cat > "${compat_dir}/yq" <<EOF
#!/usr/bin/env bash
set -euo pipefail

REAL_YQ=$(printf '%q' "${real_yq}")

  if [[ "\${1:-}" == "-o" && "\${2:-}" == "shell" ]]; then
    shift 2
    expr="\${1:-}"
    file="\${2:-}"
    [[ -n "\${expr}" && -n "\${file}" ]] || {
      echo "yq compatibility wrapper: expected '-o shell <expr> <file>'" >&2
      exit 2
    }
  json_output="\$("\${REAL_YQ}" -o=json "\${expr}" "\${file}")"
  printf '%s' "\${json_output}" | python3 -c '
import json
import shlex
import sys

data = json.load(sys.stdin)

def emit(prefix, value):
    if isinstance(value, dict):
        for key, item in value.items():
            next_prefix = f"{prefix}_{key}" if prefix else str(key)
            emit(next_prefix, item)
    elif isinstance(value, list):
        for idx, item in enumerate(value):
            next_prefix = f"{prefix}_{idx}" if prefix else str(idx)
            emit(next_prefix, item)
    else:
        if value is None:
            return
        print(f"{prefix}={shlex.quote(str(value))}")

emit("", data)
'
  exit 0
fi

exec "\${REAL_YQ}" "\$@"
EOF
  chmod u+x "${compat_dir}/yq"
  printf '%s\n' "${compat_dir}"
}

render_benchmark_config() {
  local template_path="$1"
  local output_path="$2"
  local gateway_svc

  gateway_svc="$(resolved_gateway_svc)"

  NAMESPACE="${NAMESPACE}" \
  GATEWAY_SVC="${gateway_svc}" \
  BENCHMARK_PVC="${BENCHMARK_PVC}" \
  envsubst < "${template_path}" > "${output_path}"

  log_success "Rendered benchmark config to ${output_path}."
}

benchmark_launcher_pod() {
  kubectl get pods -n "${BENCHMARK_NAMESPACE}" -l app --show-labels 2>/dev/null | awk -v p="${HARNESS_POD_NAME_PATTERN}" '$0 ~ p { print $1; exit }'
}

print_benchmark_env() {
  local template_path
  local gateway_name
  local gateway_svc

  template_path="$(resolved_template_path)"
  gateway_name="$(resolved_gateway_name 2>/dev/null || true)"
  gateway_svc="$(resolved_gateway_svc)"

  cat <<EOF
STACK_TYPE=${STACK_TYPE}
BENCHMARK_PROFILE=${BENCHMARK_PROFILE}
NAMESPACE=${NAMESPACE}
BENCHMARK_NAMESPACE=${BENCHMARK_NAMESPACE}
RELEASE_NAME_POSTFIX=$(resolved_release_name_postfix)
GATEWAY_NAME=${gateway_name}
GATEWAY_SVC=${gateway_svc}
BENCHMARK_TEMPLATE=${template_path}
BENCHMARK_PVC=${BENCHMARK_PVC}
BENCHMARK_STORAGE_CLASS=${BENCHMARK_STORAGE_CLASS}
BENCHMARK_PVC_SIZE=${BENCHMARK_PVC_SIZE}
BENCHMARK_CONFIG_PATH=${BENCHMARK_CONFIG_PATH}
RUN_ONLY_PATH=${RUN_ONLY_PATH}
EOF
}
