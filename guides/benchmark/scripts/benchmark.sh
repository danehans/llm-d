#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-help}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <env|ensure-pvc|check-pvc|render-config|download-runner|run|status|results>

Generic benchmark workflow for llm-d well-lit paths.

Required environment:
  NAMESPACE             Namespace where the stack is deployed
  STACK_TYPE            inference-scheduling | precise | pd-disaggregation | wva-inference-scheduling

Common optional environment:
  BENCHMARK_PROFILE     default | guidellm | guide | shared-prefix
  RELEASE_NAME_POSTFIX  Override guide release postfix
  GATEWAY_NAME          Override resolved gateway name
  GATEWAY_SVC           Override resolved gateway service
  BENCHMARK_TEMPLATE    Explicit benchmark template path
  BENCHMARK_PVC         Default: ${BENCHMARK_PVC}
  BENCHMARK_STORAGE_CLASS
                        Default: ${BENCHMARK_STORAGE_CLASS}
  BENCHMARK_PVC_SIZE    Default: ${BENCHMARK_PVC_SIZE}
  BENCHMARK_CONFIG_PATH Default: ${BENCHMARK_CONFIG_PATH}
  RUN_ONLY_PATH         Default: ${RUN_ONLY_PATH}
  BENCHMARK_HARNESS_CPU Optional launcher CPU override
  BENCHMARK_HARNESS_MEMORY
                        Optional launcher memory override
  BENCHMARK_HARNESS_TOLERATE_GPU_NODES
                        Set to true to let the launcher run on GPU nodes when
                        the default CPU pool is too small
EOF
}

require_base_prereqs() {
  require_cmds kubectl
  require_namespace
  require_stack_type
  namespace_exists "${NAMESPACE}" || fail "Namespace ${NAMESPACE} does not exist."
}

run_benchmark() {
  local template_path
  local compat_path_prefix
  local yq_compat_prefix
  local original_path

  require_cmds kubectl curl envsubst yq
  require_base_prereqs
  if [[ "$(uname -s)" =~ [Dd]arwin ]]; then
    require_cmds gsed
  fi

  template_path="$(resolved_template_path)"
  ensure_benchmark_pvc "${BENCHMARK_NAMESPACE}" "${BENCHMARK_PVC}" "${BENCHMARK_STORAGE_CLASS}" "${BENCHMARK_PVC_SIZE}"
  check_benchmark_pvc "${BENCHMARK_NAMESPACE}" "${BENCHMARK_PVC}" "${BENCHMARK_STORAGE_CLASS}"
  ensure_run_only
  compat_path_prefix="$(ensure_timeout_compat)"
  yq_compat_prefix="$(ensure_yq_shell_compat)"
  render_benchmark_config "${template_path}" "${BENCHMARK_CONFIG_PATH}"
  print_benchmark_env
  original_path="${PATH}"
  PATH="${original_path}"
  if [[ -n "${compat_path_prefix}" ]]; then
    PATH="${compat_path_prefix}:${PATH}"
  fi
  if [[ -n "${yq_compat_prefix}" ]]; then
    PATH="${yq_compat_prefix}:${PATH}"
  fi
  HARNESS_CPU_NR="${BENCHMARK_HARNESS_CPU:-}" \
  HARNESS_CPU_MEM="${BENCHMARK_HARNESS_MEMORY:-}" \
  HARNESS_TOLERATE_GPU_NODES="${BENCHMARK_HARNESS_TOLERATE_GPU_NODES:-}" \
  "${RUN_ONLY_PATH}" -c "${BENCHMARK_CONFIG_PATH}"
  PATH="${original_path}"
}

print_status() {
  local launcher_pod

  require_cmds kubectl
  require_base_prereqs

  launcher_pod="$(benchmark_launcher_pod)"
  if [[ -z "${launcher_pod}" ]]; then
    log_warn "No benchmark launcher pod found in namespace ${BENCHMARK_NAMESPACE}."
    return 0
  fi

  kubectl get pod "${launcher_pod}" -n "${BENCHMARK_NAMESPACE}" -o wide
}

print_results() {
  local launcher_pod

  require_cmds kubectl
  require_base_prereqs

  launcher_pod="$(benchmark_launcher_pod)"
  [[ -n "${launcher_pod}" ]] || fail "No benchmark launcher pod found in namespace ${BENCHMARK_NAMESPACE}."

  kubectl exec -n "${BENCHMARK_NAMESPACE}" "${launcher_pod}" -- ls -lah /requests
}

case "${ACTION}" in
  env)
    require_cmds kubectl
    require_base_prereqs
    print_benchmark_env
    ;;
  ensure-pvc)
    require_cmds kubectl
    require_base_prereqs
    ensure_benchmark_pvc "${BENCHMARK_NAMESPACE}" "${BENCHMARK_PVC}" "${BENCHMARK_STORAGE_CLASS}" "${BENCHMARK_PVC_SIZE}"
    kubectl get pvc "${BENCHMARK_PVC}" -n "${BENCHMARK_NAMESPACE}"
    ;;
  check-pvc)
    require_cmds kubectl
    require_base_prereqs
    check_benchmark_pvc "${BENCHMARK_NAMESPACE}" "${BENCHMARK_PVC}" "${BENCHMARK_STORAGE_CLASS}"
    kubectl get pvc "${BENCHMARK_PVC}" -n "${BENCHMARK_NAMESPACE}"
    ;;
  render-config)
    require_cmds kubectl envsubst
    require_base_prereqs
    render_benchmark_config "$(resolved_template_path)" "${BENCHMARK_CONFIG_PATH}"
    ;;
  download-runner)
    require_cmds curl
    ensure_run_only
    ;;
  run)
    run_benchmark
    ;;
  status)
    print_status
    ;;
  results)
    print_results
    ;;
  *)
    usage
    exit 1
    ;;
esac
