#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ACTION="${1:-all}"
SMOKE_CLIENT_NAME="${SMOKE_CLIENT_NAME:-${RELEASE_NAME_POSTFIX}-smoke-client}"
SMOKE_CLIENT_IMAGE="${SMOKE_CLIENT_IMAGE:-curlimages/curl:8.12.1}"
SMOKE_CLIENT_TIMEOUT_SECONDS="${SMOKE_CLIENT_TIMEOUT_SECONDS:-600}"
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-32B}"
PROMPT="${PROMPT:-Say hello in one short sentence.}"
MAX_TOKENS="${MAX_TOKENS:-32}"
BASE_URL="${BASE_URL:-http://${GATEWAY_NAME}.${NAMESPACE}.svc.cluster.local}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <client-apply|client-delete|models|completions|chat|all>

Runs smoke tests from an in-cluster curl client to avoid relying on local curl
or local port-forwarding.

Environment:
  PROJECT_ID                    Required GCP project
  NAMESPACE                     Default: ${NAMESPACE}
  RELEASE_NAME_POSTFIX          Default: ${RELEASE_NAME_POSTFIX}
  SMOKE_CLIENT_NAME             Default: ${SMOKE_CLIENT_NAME}
  SMOKE_CLIENT_IMAGE            Default: ${SMOKE_CLIENT_IMAGE}
  SMOKE_CLIENT_TIMEOUT_SECONDS  Default: ${SMOKE_CLIENT_TIMEOUT_SECONDS}
  BASE_URL                      Default: ${BASE_URL}
  MODEL_NAME                    Default: ${MODEL_NAME}
  PROMPT                        Default: ${PROMPT}
  MAX_TOKENS                    Default: ${MAX_TOKENS}
EOF
}

json_escape() {
  printf '%s' "$1" | awk '
    BEGIN { ORS = ""; first = 1 }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      if (!first) {
        printf "\\n"
      }
      printf "%s", $0
      first = 0
    }
  '
}

require_stack_prereqs() {
  require_cmds kubectl gcloud
  require_project_id
  cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
  ensure_cluster_credentials
  namespace_exists "${NAMESPACE}" || fail "Namespace ${NAMESPACE} does not exist. Install the stack first."
  service_exists "${GATEWAY_NAME}" "${NAMESPACE}" || fail "Service ${NAMESPACE}/${GATEWAY_NAME} does not exist."
  deployment_exists "${GATEWAY_DEPLOYMENT}" "${NAMESPACE}" || fail "Gateway deployment ${NAMESPACE}/${GATEWAY_DEPLOYMENT} does not exist."
  deployment_exists "${DECODE_DEPLOYMENT}" "${NAMESPACE}" || fail "Decode deployment ${NAMESPACE}/${DECODE_DEPLOYMENT} does not exist."
}

require_runtime_prereqs() {
  require_stack_prereqs
  local ready_decode
  ready_decode="$(kubectl get deployment "${DECODE_DEPLOYMENT}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  ready_decode="${ready_decode:-0}"
  (( ready_decode > 0 )) || fail "Decode deployment ${NAMESPACE}/${DECODE_DEPLOYMENT} has no ready replicas."
}

run_get_models() {
  local response
  response="$(kubectl exec -n "${NAMESPACE}" "${SMOKE_CLIENT_NAME}" -- \
    curl -fsS "${BASE_URL}/v1/models")"
  printf '%s\n' "${response}"
  grep -Fq "\"${MODEL_NAME}\"" <<<"${response}" || fail "/v1/models response did not include ${MODEL_NAME}."
  log_success "/v1/models returned ${MODEL_NAME}."
}

run_post_json() {
  local url="$1"
  local payload_file="$2"

  kubectl exec -i -n "${NAMESPACE}" "${SMOKE_CLIENT_NAME}" -- sh -ceu '
req=/tmp/request.json
cat >"${req}"
curl -fsS -H "Content-Type: application/json" --data @"${req}" "$1"
' sh "${url}" < "${payload_file}"
}

run_completions() {
  local payload_file
  local escaped_prompt
  local response

  escaped_prompt="$(json_escape "${PROMPT}")"
  payload_file="$(mktemp)"
  cat > "${payload_file}" <<EOF
{"model":"$(json_escape "${MODEL_NAME}")","prompt":"${escaped_prompt}","max_tokens":${MAX_TOKENS}}
EOF

  response="$(run_post_json "${BASE_URL}/v1/completions" "${payload_file}")"
  rm -f "${payload_file}"

  printf '%s\n' "${response}"
  grep -Fq '"choices"' <<<"${response}" || fail "/v1/completions response did not include choices."
  log_success "/v1/completions returned a completion payload."
}

run_chat_completions() {
  local payload_file
  local escaped_prompt
  local response

  escaped_prompt="$(json_escape "${PROMPT}")"
  payload_file="$(mktemp)"
  cat > "${payload_file}" <<EOF
{"model":"$(json_escape "${MODEL_NAME}")","messages":[{"role":"user","content":"${escaped_prompt}"}],"max_tokens":${MAX_TOKENS}}
EOF

  response="$(run_post_json "${BASE_URL}/v1/chat/completions" "${payload_file}")"
  rm -f "${payload_file}"

  printf '%s\n' "${response}"
  grep -Fq '"choices"' <<<"${response}" || fail "/v1/chat/completions response did not include choices."
  log_success "/v1/chat/completions returned a chat payload."
}

case "${ACTION}" in
  client-delete)
    require_cmds kubectl gcloud
    require_project_id
    cluster_exists || fail "Cluster ${CLUSTER_NAME} does not exist."
    ensure_cluster_credentials
    namespace_exists "${NAMESPACE}" || fail "Namespace ${NAMESPACE} does not exist."
    delete_smoke_client "${NAMESPACE}" "${SMOKE_CLIENT_NAME}"
    log_success "Deleted smoke client ${NAMESPACE}/${SMOKE_CLIENT_NAME}."
    ;;
  client-apply)
    require_stack_prereqs
    ensure_smoke_client "${NAMESPACE}" "${SMOKE_CLIENT_NAME}" "${SMOKE_CLIENT_IMAGE}" "${SMOKE_CLIENT_TIMEOUT_SECONDS}"
    ;;
  models)
    require_runtime_prereqs
    ensure_smoke_client "${NAMESPACE}" "${SMOKE_CLIENT_NAME}" "${SMOKE_CLIENT_IMAGE}" "${SMOKE_CLIENT_TIMEOUT_SECONDS}"
    run_get_models
    ;;
  completions)
    require_runtime_prereqs
    ensure_smoke_client "${NAMESPACE}" "${SMOKE_CLIENT_NAME}" "${SMOKE_CLIENT_IMAGE}" "${SMOKE_CLIENT_TIMEOUT_SECONDS}"
    run_completions
    ;;
  chat)
    require_runtime_prereqs
    ensure_smoke_client "${NAMESPACE}" "${SMOKE_CLIENT_NAME}" "${SMOKE_CLIENT_IMAGE}" "${SMOKE_CLIENT_TIMEOUT_SECONDS}"
    run_chat_completions
    ;;
  all)
    require_runtime_prereqs
    ensure_smoke_client "${NAMESPACE}" "${SMOKE_CLIENT_NAME}" "${SMOKE_CLIENT_IMAGE}" "${SMOKE_CLIENT_TIMEOUT_SECONDS}"
    run_get_models
    run_completions
    run_chat_completions
    ;;
  *)
    usage
    exit 1
    ;;
esac
