#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-status}"
TARGET_GPU_NODES="${TARGET_GPU_NODES:-}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-3600}"
WINNER_ENV_FILE="${WINNER_ENV_FILE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <discover-candidates|ensure-nodegroups|race|status|cleanup>

Environment:
  AWS_PROFILE          Default: ${AWS_PROFILE}
  AWS_REGION           Default: ${AWS_REGION}
  CLUSTER_NAME         Default: ${CLUSTER_NAME}
  GPU_CAPACITY_MODE    Default: ${GPU_CAPACITY_MODE}
  GPU_INSTANCE_TYPE    Default: ${GPU_INSTANCE_TYPE}
  GPU_CANDIDATE_AZS    Optional comma-separated AZ list
  TARGET_GPU_NODES     Required for race
  WAIT_TIMEOUT_SECONDS Default: ${WAIT_TIMEOUT_SECONDS}
EOF
}

discover_candidates() {
  effective_candidate_azs
}

ensure_nodegroups() {
  cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
  ensure_cluster_credentials
  ensure_gpu_candidate_nodegroups
}

write_winner_env() {
  local nodegroup="$1"
  local az="$2"
  local ready_nodes="$3"
  local reservation_id="${4:-}"

  if [[ -n "${WINNER_ENV_FILE}" ]]; then
    cat > "${WINNER_ENV_FILE}" <<EOF
WINNER_NODEGROUP=${nodegroup}
WINNER_AZ=${az}
WINNER_READY_NODES=${ready_nodes}
WINNER_CAPACITY_RESERVATION_ID=${reservation_id}
EOF
  fi
}

scale_losers_to_zero() {
  local winner="$1"
  local spec nodegroup

  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    IFS='|' read -r nodegroup _ <<<"${spec}"
    [[ "${nodegroup}" == "${winner}" ]] && continue
    if nodegroup_exists "${nodegroup}"; then
      set_nodegroup_scale "${nodegroup}" 0 0 "${GPU_MAX_NODES}"
    fi
  done < <(gpu_candidate_specs)
}

status_capacity() {
  local spec nodegroup az ready status reservation_id reservation_state available total

  if ! cluster_exists; then
    log_warn "Cluster ${CLUSTER_NAME} does not exist."
    return 0
  fi

  ensure_cluster_credentials
  printf 'NODEGROUP\tAZ\tSTATUS\tREADY\tRESERVATION_ID\tRESERVATION_STATE\tAVAILABLE\tTOTAL\n'
  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    IFS='|' read -r nodegroup az <<<"${spec}"
    if nodegroup_exists "${nodegroup}"; then
      status="$(nodegroup_status "${nodegroup}")"
      ready="$(ready_node_count "${nodegroup}")"
    else
      status="MISSING"
      ready="0"
    fi

    reservation_id="$(cluster_capacity_reservation_ids "${az}" 'active,pending' | head -n1)"
    if [[ -z "${reservation_id}" ]]; then
      reservation_id="$(cluster_capacity_reservation_ids "${az}" 'cancelled' | head -n1)"
    fi
    reservation_state=""
    available=""
    total=""
    if [[ -n "${reservation_id}" ]]; then
      reservation_state="$(capacity_reservation_state "${reservation_id}")"
      available="$(capacity_reservation_available_instance_count "${reservation_id}")"
      total="$(capacity_reservation_instance_count "${reservation_id}")"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${nodegroup}" "${az}" "${status}" "${ready}" \
      "${reservation_id:-<none>}" "${reservation_state:-<none>}" \
      "${available:-<none>}" "${total:-<none>}"
  done < <(gpu_candidate_specs)
}

cleanup_capacity() {
  if cluster_exists; then
    ensure_cluster_credentials
    scale_losers_to_zero ""
  fi
  cleanup_cluster_capacity_reservations
}

wait_for_attempts_to_finish() {
  local pid
  for pid in "$@"; do
    wait "${pid}" >/dev/null 2>&1 || true
  done
}

all_attempts_finished() {
  local pid
  for pid in "$@"; do
    if kill -0 "${pid}" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

odcr_attempt_create() {
  local az="$1"
  local target_nodes="$2"
  local output_prefix="$3"
  local result
  local -a args=(
    ec2 create-capacity-reservation
    --instance-type "${GPU_INSTANCE_TYPE}"
    --instance-platform "${ODCR_INSTANCE_PLATFORM}"
    --availability-zone "${az}"
    --instance-count "${target_nodes}"
    --instance-match-criteria "${ODCR_INSTANCE_MATCH_CRITERIA}"
    --end-date-type "${ODCR_END_DATE_TYPE}"
    --tag-specifications "$(capacity_reservation_tag_spec_for_az "${az}")"
    --query 'CapacityReservation.[CapacityReservationId,State,AvailabilityZone]'
    --output text
  )

  if [[ -n "${ODCR_END_DATE}" ]]; then
    args+=(--end-date "${ODCR_END_DATE}")
  fi

  if result="$(aws_cmd "${args[@]}" 2>&1)"; then
    printf '%s\n' "${result}" > "${output_prefix}.success"
  else
    printf '%s\n' "${result}" > "${output_prefix}.error"
    return 1
  fi
}

cancel_loser_reservations() {
  local winner_reservation_id="$1"
  local reservation_id

  while IFS= read -r reservation_id; do
    [[ -n "${reservation_id}" ]] || continue
    [[ "${reservation_id}" == "${winner_reservation_id}" ]] && continue
    cancel_capacity_reservation_if_present "${reservation_id}"
  done < <(cluster_capacity_reservation_ids "" "active,pending")
}

print_odcr_failures() {
  local attempts_dir="$1"
  local spec nodegroup az error_file

  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    IFS='|' read -r nodegroup az <<<"${spec}"
    error_file="${attempts_dir}/${nodegroup}.error"
    if [[ -f "${error_file}" ]]; then
      log_warn "ODCR create failed in ${az}:"
      sed 's/^/  /' "${error_file}"
    fi
  done < <(gpu_candidate_specs)
}

race_on_demand_capacity() {
  local deadline spec nodegroup az winner ready active

  [[ -n "${TARGET_GPU_NODES}" ]] || fail "Set TARGET_GPU_NODES before running race."
  cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
  ensure_cluster_credentials
  ensure_gpu_candidate_nodegroups

  active="$(active_gpu_nodegroup)"
  if [[ -n "${active}" ]]; then
    log_info "Found active GPU nodegroup ${active}; scaling it directly to ${TARGET_GPU_NODES} node(s)."
    set_nodegroup_scale "${active}" "${TARGET_GPU_NODES}" 0 "${GPU_MAX_NODES}"
    wait_for_ready_node_count "${active}" "${TARGET_GPU_NODES}" "${WAIT_TIMEOUT_SECONDS}"
    while IFS= read -r spec; do
      IFS='|' read -r nodegroup az <<<"${spec}"
      if [[ "${nodegroup}" == "${active}" ]]; then
        write_winner_env "${nodegroup}" "${az}" "${TARGET_GPU_NODES}"
        log_success "Winner nodegroup ${nodegroup} in ${az} is ready."
        return 0
      fi
    done < <(gpu_candidate_specs)
  fi

  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    IFS='|' read -r nodegroup _ <<<"${spec}"
    set_nodegroup_scale "${nodegroup}" "${TARGET_GPU_NODES}" 0 "${GPU_MAX_NODES}"
  done < <(gpu_candidate_specs)

  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
  while true; do
    while IFS= read -r spec; do
      [[ -n "${spec}" ]] || continue
      IFS='|' read -r nodegroup az <<<"${spec}"
      ready="$(ready_node_count "${nodegroup}")"
      if (( ready >= TARGET_GPU_NODES )); then
        winner="${nodegroup}"
        scale_losers_to_zero "${winner}"
        write_winner_env "${winner}" "${az}" "${ready}"
        log_success "Winner nodegroup ${winner} in ${az} reached ${ready} ready node(s)."
        return 0
      fi
    done < <(gpu_candidate_specs)

    if (( $(date +%s) >= deadline )); then
      fail "Timed out waiting for any GPU nodegroup to reach ${TARGET_GPU_NODES} ready node(s)."
    fi
    sleep 15
  done
}

race_odcr_capacity() {
  local attempts_dir deadline found_winner winner_nodegroup winner_az winner_reservation_id
  local spec nodegroup az ready success_file active active_ready active_az
  local -a attempt_pids=()

  [[ -n "${TARGET_GPU_NODES}" ]] || fail "Set TARGET_GPU_NODES before running race."
  cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
  ensure_cluster_credentials
  ensure_gpu_candidate_nodegroups

  active="$(active_gpu_nodegroup)"
  if [[ -n "${active}" ]]; then
    active_ready="$(ready_node_count "${active}")"
    if (( active_ready >= TARGET_GPU_NODES )); then
      while IFS= read -r spec; do
        IFS='|' read -r nodegroup az <<<"${spec}"
        if [[ "${nodegroup}" == "${active}" ]]; then
          write_winner_env "${nodegroup}" "${az}" "${active_ready}" "$(cluster_capacity_reservation_ids "${az}" 'active,pending' | head -n1)"
          log_success "Existing GPU nodegroup ${nodegroup} in ${az} already satisfies the target."
          return 0
        fi
      done < <(gpu_candidate_specs)
    fi
    fail "ODCR scale-up with an existing partial GPU fleet is not implemented safely yet. Current nodegroup ${active} has ${active_ready} ready node(s)."
  fi

  cleanup_cluster_capacity_reservations

  attempts_dir="$(mktemp -d)"
  trap 'rm -rf "${attempts_dir}"' RETURN

  while IFS= read -r spec; do
    [[ -n "${spec}" ]] || continue
    IFS='|' read -r nodegroup az <<<"${spec}"
    odcr_attempt_create "${az}" "${TARGET_GPU_NODES}" "${attempts_dir}/${nodegroup}" &
    attempt_pids+=("$!")
  done < <(gpu_candidate_specs)

  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
  while true; do
    if [[ -z "${found_winner:-}" ]]; then
      while IFS= read -r spec; do
        [[ -n "${spec}" ]] || continue
        IFS='|' read -r nodegroup az <<<"${spec}"
        success_file="${attempts_dir}/${nodegroup}.success"
        if [[ -f "${success_file}" ]]; then
          read -r winner_reservation_id _ winner_az < "${success_file}"
          winner_nodegroup="${nodegroup}"
          found_winner="true"
          break
        fi
      done < <(gpu_candidate_specs)

      if [[ -n "${found_winner:-}" ]]; then
        wait_for_capacity_reservation_state "${winner_reservation_id}" "active" "${WAIT_TIMEOUT_SECONDS}"
        set_nodegroup_scale "${winner_nodegroup}" "${TARGET_GPU_NODES}" 0 "${GPU_MAX_NODES}"
        wait_for_attempts_to_finish "${attempt_pids[@]}"
        cancel_loser_reservations "${winner_reservation_id}"
        scale_losers_to_zero "${winner_nodegroup}"
        wait_for_ready_node_count "${winner_nodegroup}" "${TARGET_GPU_NODES}" "${WAIT_TIMEOUT_SECONDS}"
        ready="$(ready_node_count "${winner_nodegroup}")"
        write_winner_env "${winner_nodegroup}" "${winner_az}" "${ready}" "${winner_reservation_id}"
        log_success "Winner reservation ${winner_reservation_id} in ${winner_az} backed nodegroup ${winner_nodegroup} with ${ready} ready node(s)."
        return 0
      fi
    fi

    if all_attempts_finished "${attempt_pids[@]}"; then
      print_odcr_failures "${attempts_dir}"
      fail "Immediate-use ODCR could not be created in any candidate AZ."
    fi

    if (( $(date +%s) >= deadline )); then
      wait_for_attempts_to_finish "${attempt_pids[@]}"
      print_odcr_failures "${attempts_dir}"
      fail "Timed out waiting for an immediate-use ODCR winner."
    fi
    sleep 5
  done
}

race_capacity() {
  case "${GPU_CAPACITY_MODE}" in
    on-demand)
      race_on_demand_capacity
      ;;
    odcr)
      race_odcr_capacity
      ;;
    *)
      fail "GPU_CAPACITY_MODE=${GPU_CAPACITY_MODE} is not implemented in capacity.sh yet."
      ;;
  esac
}

require_cmds aws eksctl kubectl
require_aws_profile
ensure_supported_capacity_mode

case "${ACTION}" in
  discover-candidates)
    discover_candidates
    ;;
  ensure-nodegroups)
    ensure_nodegroups
    ;;
  race)
    race_capacity
    ;;
  status)
    status_capacity
    ;;
  cleanup)
    cleanup_capacity
    ;;
  *)
    usage
    exit 1
    ;;
esac
