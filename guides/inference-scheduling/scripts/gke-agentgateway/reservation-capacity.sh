#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-help}"
readonly ADVICE_PERMISSION="compute.advice.calendarMode"
readonly CREATE_FUTURE_PERMISSIONS=(
  "compute.futureReservations.create"
  "compute.reservations.create"
)
readonly GPU_FUTURE_RESERVATION_MIN_DURATION_SECONDS=86400
ADVICE_START_FROM="${ADVICE_START_FROM:-}"
ADVICE_START_TO="${ADVICE_START_TO:-}"
ADVICE_DURATION_MIN="${ADVICE_DURATION_MIN:-24h}"
ADVICE_DURATION_MAX="${ADVICE_DURATION_MAX:-24h}"
ADVICE_LOCATION_POLICY="${ADVICE_LOCATION_POLICY:-}"
FUTURE_START_TIME="${FUTURE_START_TIME:-}"
FUTURE_DURATION="${FUTURE_DURATION:-}"
FUTURE_END_TIME="${FUTURE_END_TIME:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <check-permissions|advice|create-future|describe-future|describe-reservation|ensure-pool|status>

Reservation-backed H100 workflow for the GKE + agentgateway well-lit path.

This path is intended for reservable A3 shapes such as ${H100_RESERVED_MACHINE_TYPE}.
It is separate from the queued A3 2g flow.

Environment:
  PROJECT_ID                     Required GCP project
  H100_CAPACITY_MODE             Must be reservation
  H100_RESERVED_ZONE             Default: ${H100_RESERVED_ZONE}
  H100_RESERVED_MACHINE_TYPE     Default: ${H100_RESERVED_MACHINE_TYPE}
  H100_RESERVED_GPU_TYPE         Default: ${H100_RESERVED_GPU_TYPE}
  H100_RESERVED_GPUS_PER_NODE    Default: ${H100_RESERVED_GPUS_PER_NODE}
  H100_RESERVED_MAX_NODES        Default: ${H100_RESERVED_MAX_NODES}
  H100_RESERVED_RESERVATION_NAME Default: ${H100_RESERVED_RESERVATION_NAME}
  H100_FUTURE_RESERVATION_NAME   Default: ${H100_FUTURE_RESERVATION_NAME}
  H100_FUTURE_RESERVATION_VM_COUNT
                                 Default: ${H100_FUTURE_RESERVATION_VM_COUNT}

Advice defaults:
  ADVICE_START_FROM              Default: now + 96h (UTC)
  ADVICE_START_TO                Default: now + 168h (UTC)
  ADVICE_DURATION_MIN            Default: ${ADVICE_DURATION_MIN}
  ADVICE_DURATION_MAX            Default: ${ADVICE_DURATION_MAX}
  ADVICE_LOCATION_POLICY         Default: ${H100_RESERVED_ZONE}=ALLOW

Create-future requirements:
  FUTURE_START_TIME              Required RFC3339 UTC timestamp
  FUTURE_DURATION                Required unless FUTURE_END_TIME is set.
                                 Accepts values like 86400, 24h, 1440m, or 1d
  FUTURE_END_TIME                Optional alternative to FUTURE_DURATION
                                 GPU calendar-mode reservations must be at
                                 least 24h and use deployment type DENSE

Permission checks:
  advice                         Requires ${ADVICE_PERMISSION}
  create-future                  Requires ${CREATE_FUTURE_PERMISSIONS[*]}
  check-permissions              Verifies all reservation-mode permissions
EOF
}

default_advice_window() {
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)
print((now + timedelta(hours=96)).strftime("%Y-%m-%dT%H:%M:%SZ"))
print((now + timedelta(hours=168)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

effective_advice_window() {
  local default_from
  local default_to

  if [[ -n "${ADVICE_START_FROM}" && -n "${ADVICE_START_TO}" ]]; then
    printf '%s\n%s\n' "${ADVICE_START_FROM}" "${ADVICE_START_TO}"
    return 0
  fi

  mapfile -t defaults < <(default_advice_window)
  default_from="${defaults[0]}"
  default_to="${defaults[1]}"
  printf '%s\n%s\n' "${ADVICE_START_FROM:-${default_from}}" "${ADVICE_START_TO:-${default_to}}"
}

effective_location_policy() {
  if [[ -n "${ADVICE_LOCATION_POLICY}" ]]; then
    printf '%s\n' "${ADVICE_LOCATION_POLICY}"
  else
    printf '%s=ALLOW\n' "${H100_RESERVED_ZONE}"
  fi
}

future_reservation_exists() {
  gcloud compute future-reservations describe "${H100_FUTURE_RESERVATION_NAME}" \
    --zone "${H100_RESERVED_ZONE}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1
}

check_reservation_permissions() {
  local mode="${1:-all}"

  case "${mode}" in
    advice)
      require_project_permissions "${ADVICE_PERMISSION}"
      log_success "Verified ${ADVICE_PERMISSION} on project ${PROJECT_ID}."
      ;;
    create-future)
      require_project_permissions "${CREATE_FUTURE_PERMISSIONS[@]}"
      log_success "Verified ${CREATE_FUTURE_PERMISSIONS[*]} on project ${PROJECT_ID}."
      ;;
    all)
      require_project_permissions "${ADVICE_PERMISSION}" "${CREATE_FUTURE_PERMISSIONS[@]}"
      log_success "Verified reservation-mode permissions on project ${PROJECT_ID}."
      ;;
    *)
      fail "Unsupported permission check mode: ${mode}"
      ;;
  esac
}

print_advice() {
  local advice_from
  local advice_to
  local policy
  mapfile -t advice_window < <(effective_advice_window)
  advice_from="${advice_window[0]}"
  advice_to="${advice_window[1]}"
  policy="$(effective_location_policy)"

  gcloud beta compute advice calendar-mode \
    --project "${PROJECT_ID}" \
    --region "$(reservation_region)" \
    --machine-type "${H100_RESERVED_MACHINE_TYPE}" \
    --vm-count "${H100_FUTURE_RESERVATION_VM_COUNT}" \
    --start-time-range="from=${advice_from},to=${advice_to}" \
    --duration-range="min=${ADVICE_DURATION_MIN},max=${ADVICE_DURATION_MAX}" \
    --location-policy="${policy}"
}

create_future_reservation() {
  local cmd
  local duration_seconds

  [[ -n "${FUTURE_START_TIME}" ]] || fail "Set FUTURE_START_TIME before creating a future reservation."
  if [[ -z "${FUTURE_DURATION}" && -z "${FUTURE_END_TIME}" ]]; then
    fail "Set FUTURE_DURATION or FUTURE_END_TIME before creating a future reservation."
  fi

  cmd=(
    gcloud compute future-reservations create "${H100_FUTURE_RESERVATION_NAME}"
    --project "${PROJECT_ID}"
    --zone "${H100_RESERVED_ZONE}"
    --machine-type "${H100_RESERVED_MACHINE_TYPE}"
    --accelerator "count=${H100_RESERVED_GPUS_PER_NODE},type=${H100_RESERVED_GPU_TYPE}"
    --deployment-type DENSE
    --reservation-mode CALENDAR
    --require-specific-reservation
    --reservation-name "${H100_RESERVED_RESERVATION_NAME}"
    --planning-status SUBMITTED
    --auto-delete-auto-created-reservations
    --start-time "${FUTURE_START_TIME}"
    --total-count "${H100_FUTURE_RESERVATION_VM_COUNT}"
  )

  if [[ -n "${FUTURE_DURATION}" ]]; then
    duration_seconds="$(normalize_duration_seconds "${FUTURE_DURATION}")"
    if (( duration_seconds < GPU_FUTURE_RESERVATION_MIN_DURATION_SECONDS )); then
      fail "GPU future reservations in calendar mode must be at least 24h. FUTURE_DURATION=${FUTURE_DURATION} resolves to ${duration_seconds}s."
    fi
    cmd+=(--duration "${duration_seconds}")
  else
    cmd+=(--end-time "${FUTURE_END_TIME}")
  fi

  "${cmd[@]}"
}

describe_future_reservation() {
  future_reservation_exists || fail "Future reservation ${H100_FUTURE_RESERVATION_NAME} does not exist in ${H100_RESERVED_ZONE}."
  gcloud compute future-reservations describe "${H100_FUTURE_RESERVATION_NAME}" \
    --project "${PROJECT_ID}" \
    --zone "${H100_RESERVED_ZONE}"
}

describe_active_reservation() {
  reservation_exists || fail "Reservation ${H100_RESERVED_RESERVATION_NAME} does not exist in ${H100_RESERVED_ZONE}."
  gcloud compute reservations describe "${H100_RESERVED_RESERVATION_NAME}" \
    --project "${PROJECT_ID}" \
    --zone "${H100_RESERVED_ZONE}"
}

print_status() {
  printf '\nFuture Reservation\n'
  if future_reservation_exists; then
    gcloud compute future-reservations describe "${H100_FUTURE_RESERVATION_NAME}" \
      --project "${PROJECT_ID}" \
      --zone "${H100_RESERVED_ZONE}"
  else
    echo "Future reservation not found."
  fi

  printf '\nActive Reservation\n'
  if reservation_exists; then
    gcloud compute reservations describe "${H100_RESERVED_RESERVATION_NAME}" \
      --project "${PROJECT_ID}" \
      --zone "${H100_RESERVED_ZONE}"
  else
    echo "Reservation not found."
  fi

  printf '\nReservation-backed Node Pool\n'
  if cluster_exists && nodepool_exists "${H100_RESERVED_NODEPOOL}"; then
    gcloud container node-pools describe "${H100_RESERVED_NODEPOOL}" \
      --cluster "${CLUSTER_NAME}" \
      --zone "${CLUSTER_ZONE}" \
      --project "${PROJECT_ID}"
  else
    echo "Node pool not found."
  fi
}

require_cmds gcloud kubectl python3 curl
require_project_id
ensure_supported_capacity_mode
capacity_mode_is_reservation || fail "Set H100_CAPACITY_MODE=reservation before using reservation-capacity.sh."

case "${ACTION}" in
  check-permissions)
    check_reservation_permissions all
    ;;
  advice)
    check_reservation_permissions advice
    print_advice
    ;;
  create-future)
    check_reservation_permissions create-future
    create_future_reservation
    ;;
  describe-future)
    describe_future_reservation
    ;;
  describe-reservation)
    describe_active_reservation
    ;;
  ensure-pool)
    cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
    ensure_cluster_credentials
    ensure_reserved_pool
    ;;
  status)
    print_status
    ;;
  *)
    usage
    exit 1
    ;;
esac
