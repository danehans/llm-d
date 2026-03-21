# GKE Handoff Package

This document is the operator-focused runbook for the GKE validation package captured in this
repository. It explains how to recreate the supported comparison flows, what artifacts to save,
and how to interpret the committed comparison CSVs and result bundles.

For the historical validation status and the final artifact index, see
[VALIDATION-TRACKER.md](./VALIDATION-TRACKER.md).

## What This Package Is For

The main goal is to compare a backend-only baseline against routed traffic for the same well-lit
path on the same cluster shape:

- **baseline flow**: generator -> direct Kubernetes Service -> vLLM pods
- **routed flow**: generator -> inference gateway -> `agentgateway` -> EPP -> vLLM pods

For predicted-latency scheduling, the routed flow stays on the gateway but uses request headers to
select the prediction-enabled `InferencePool`.

## Historical Cluster Profile

The original runs used a zonal GKE cluster with the following effective shape:

- zone: `us-central1-b`
- GKE version: `1.34.4-gke.1047000`
- GPU pool: `2 x a3-highgpu-8g` (`16 x H100 80GB` total)
- control-plane capacity for EPP: `e2-standard-8`
- general system capacity: `e2-standard-4`
- benchmark namespace: `llmd`
- benchmark storage: RWX PVC backed by Filestore CSI

The exact cloud provisioning commands are intentionally not hard-coded here because project,
network, and capacity-acquisition details vary. What matters is recreating the shape above and then
following the guide and benchmark steps below.

## Shared Software Inputs

The successful comparison runs used:

- Gateway API CRDs: `v1.5.1`
- Gateway API Inference Extension: `v1.4.0`
- `agentgateway`: `v1.0.0`
- local `llm-d-infra` chart override from `llm-d-incubation/llm-d-infra#272`
- scheduler image: `docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.2`
- routing sidecar image when needed: `docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.2`
- precise-compatible model image: `docker.io/vllm/vllm-openai:nightly-39474513f6631b1bc39a2400126bd7ff9394a774`

## Common Prerequisites

### Cluster-side prerequisites

Before starting any guide deployment, ensure the cluster already has:

- a healthy GKE control plane and the node-pool shape described above
- Gateway API and GAIE CRDs installed
- `agentgateway` installed and healthy
- monitoring installed
- a namespace for guide installs, for example `llmd`
- a valid `llm-d-hf-token` secret in that namespace
- a `ReadWriteMany` PVC of at least `200Gi` for benchmark outputs

### Local prerequisites

On the client side, install:

- `kubectl`
- `helm`
- `helmfile`
- `jq`
- `yq` v4+
- `curl`

If you are running the benchmark harness from macOS, also install GNU `timeout`:

```bash
brew install coreutils
```

We used the upstream `run_only.sh` benchmark launcher from `llm-d-benchmark`. On macOS and on
small CPU pools, be prepared to tune your downloaded copy if launcher readiness or default
resource requests are too aggressive for your environment.

### Shared environment

```bash
export NAMESPACE=llmd
export BENCHMARK_PVC=<your-rwx-pvc>
export LLMD_ROOT_DIR=/path/to/llm-d
export BENCH_TEMPLATE_DIR="${LLMD_ROOT_DIR}/guides/benchmark"
```

## Baseline vs Routed Flow

The baseline/routed split is the key to this handoff package.

### Baseline flow

- create a narrow `ClusterIP` Service that selects only the decode pods for the guide under test
- point the benchmark generator at that Service
- traffic bypasses both the gateway and EPP

### Routed flow

- keep the same backend deployment
- point the benchmark generator at the guide’s gateway Service
- for predicted-latency, add the request headers that select the alternate `InferencePool`

This means any change between the two runs is due to routing and scheduling behavior, not a
different model deployment.

## Reproduce: Inference Scheduling Shared-Prefix Comparison

### 1. Deploy the guide

```bash
cd "${LLMD_ROOT_DIR}/guides/inference-scheduling"
export LLMD_INFRA_CHART=/path/to/llm-d-infra/charts/llm-d-infra
export LLMD_MODELSERVER_IMAGE=docker.io/vllm/vllm-openai:nightly-39474513f6631b1bc39a2400126bd7ff9394a774
helmfile apply -e agentgateway -n "${NAMESPACE}"
kubectl apply -n "${NAMESPACE}" -f httproute.yaml
kubectl apply -n "${NAMESPACE}" -f direct-service.yaml
```

### 2. Smoke test both paths

Direct baseline:

```bash
kubectl port-forward -n "${NAMESPACE}" svc/ms-inference-scheduling-direct 8080:80
```

Gateway path:

```bash
kubectl port-forward -n "${NAMESPACE}" svc/infra-inference-scheduling-inference-gateway 18080:80
```

In another terminal, verify `/v1/models`, `/v1/completions`, and `/v1/chat/completions` on both
ports.

### 3. Run the direct baseline benchmark

```bash
curl -L -O https://raw.githubusercontent.com/llm-d/llm-d-benchmark/main/existing_stack/run_only.sh
chmod u+x run_only.sh

export GATEWAY_SVC=ms-inference-scheduling-direct
export BENCHMARK_TEMPLATE="${BENCH_TEMPLATE_DIR}/inference_scheduling_shared_prefix_template.yaml"
envsubst < "${BENCHMARK_TEMPLATE}" > config.yaml
yq -i '.endpoint.stack_name = "inference-scheduling-direct-shared-prefix"' config.yaml
./run_only.sh -c config.yaml
```

While the benchmark runs, capture decode logs:

```bash
kubectl logs -n "${NAMESPACE}" \
  -l app.kubernetes.io/instance=ms-inference-scheduling \
  --all-containers=true --since=10m --timestamps > /tmp/inference-scheduling-direct-decode.log
```

### 4. Run the routed benchmark

```bash
export GATEWAY_SVC=infra-inference-scheduling-inference-gateway
envsubst < "${BENCHMARK_TEMPLATE}" > config.yaml
yq -i '.endpoint.stack_name = "inference-scheduling-epp-shared-prefix"' config.yaml
./run_only.sh -c config.yaml
```

Capture both decode and EPP logs during the routed run:

```bash
kubectl logs -n "${NAMESPACE}" \
  -l app.kubernetes.io/instance=ms-inference-scheduling \
  --all-containers=true --since=10m --timestamps > /tmp/inference-scheduling-epp-decode.log

kubectl logs -n "${NAMESPACE}" \
  -l app.kubernetes.io/instance=gaie-inference-scheduling \
  --all-containers=true --since=10m --timestamps > /tmp/inference-scheduling-epp.log
```

### 5. Copy results

Copy the two results directories off the harness pod and preserve:

- `config.yaml`
- `stage_*_lifecycle_metrics.json`
- `benchmark_report_v0.2,_stage_*.yaml` when present
- `summary_lifecycle_metrics.json`
- `stdout.log`
- `stderr.log`

The committed reference artifact for this comparison is:

- [shared-prefix-comparison.csv](../../../benchmark-comparisons/shared-prefix-comparison.csv)

The full raw benchmark bundles used to generate that CSV are intentionally kept local because they
are too large for normal git history.

## Reproduce: Precise Guide Comparison

### 1. Deploy the guide

```bash
cd "${LLMD_ROOT_DIR}/guides/precise-prefix-cache-aware"
export LLMD_INFRA_CHART=/path/to/llm-d-infra/charts/llm-d-infra
export LLMD_MODELSERVER_IMAGE=docker.io/vllm/vllm-openai:nightly-39474513f6631b1bc39a2400126bd7ff9394a774
helmfile apply -e agentgateway -n "${NAMESPACE}"
kubectl apply -n "${NAMESPACE}" -f httproute.yaml
kubectl apply -n "${NAMESPACE}" -f direct-service.yaml
```

### 2. Smoke test both paths

Direct baseline:

```bash
kubectl port-forward -n "${NAMESPACE}" svc/ms-kv-events-direct 8080:80
```

Gateway path:

```bash
kubectl port-forward -n "${NAMESPACE}" svc/infra-kv-events-inference-gateway 18080:80
```

Verify `/v1/models`, `/v1/completions`, and `/v1/chat/completions` on both ports.

### 3. Run the direct baseline benchmark

```bash
export GATEWAY_SVC=ms-kv-events-direct
export BENCHMARK_TEMPLATE="${BENCH_TEMPLATE_DIR}/precise_guide_template.yaml"
envsubst < "${BENCHMARK_TEMPLATE}" > config.yaml
yq -i '.endpoint.stack_name = "precise-direct-guide"' config.yaml
./run_only.sh -c config.yaml
```

Capture decode logs:

```bash
kubectl logs -n "${NAMESPACE}" \
  -l app.kubernetes.io/instance=ms-kv-events \
  --all-containers=true --since=15m --timestamps > /tmp/precise-direct-guide-decode.log
```

### 4. Run the routed benchmark

```bash
export GATEWAY_SVC=infra-kv-events-inference-gateway
envsubst < "${BENCHMARK_TEMPLATE}" > config.yaml
yq -i '.endpoint.stack_name = "precise-epp-guide"' config.yaml
./run_only.sh -c config.yaml
```

Capture decode and EPP logs:

```bash
kubectl logs -n "${NAMESPACE}" \
  -l app.kubernetes.io/instance=ms-kv-events \
  --all-containers=true --since=15m --timestamps > /tmp/precise-epp-guide-decode.log

kubectl logs -n "${NAMESPACE}" \
  -l app.kubernetes.io/instance=gaie-kv-events \
  --all-containers=true --since=15m --timestamps > /tmp/precise-epp-guide-epp.log
```

### 5. Copy results

The committed reference artifact for this comparison is:

- [precise-guide-comparison.csv](../../../benchmark-comparisons/precise-guide-comparison.csv)

The full raw benchmark bundles used to generate that CSV are intentionally kept local because they
are too large for normal git history.

## Reproduce: Predicted-Latency Comparison

This workflow layers a second `InferencePool` on top of the precise backend.

### 1. Deploy the precise backend first

Follow the precise steps above through the point where both the gateway and direct Service are
healthy.

### 2. Install the prediction-enabled pool

```bash
helm upgrade --install gaie-predicted-latency \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.4.0 \
  -n "${NAMESPACE}" \
  -f "${LLMD_ROOT_DIR}/guides/predicted-latency-based-scheduling/values.yaml"

kubectl apply -n "${NAMESPACE}" \
  -f "${LLMD_ROOT_DIR}/guides/predicted-latency-based-scheduling/httproute.yaml"
```

### 3. Run the direct baseline

```bash
export GATEWAY_SVC=ms-kv-events-direct
export BENCHMARK_TEMPLATE="${BENCH_TEMPLATE_DIR}/predicted_latency_template.yaml"
./run_only.sh -c "${BENCHMARK_TEMPLATE}"
```

### 4. Run the prediction-enabled routed path

```bash
export GATEWAY_SVC=infra-kv-events-inference-gateway
cp "${BENCH_TEMPLATE_DIR}/predicted_latency_template.yaml" /tmp/predicted-latency-benchmark.yaml
yq -i '.workload[] .api.headers = {"x-routing-scenario":"predicted-latency","x-slo-ttft-ms":"5000","x-slo-tpot-ms":"100"}' \
  /tmp/predicted-latency-benchmark.yaml
./run_only.sh -c /tmp/predicted-latency-benchmark.yaml
```

Capture the EPP evidence:

```bash
kubectl logs -n "${NAMESPACE}" \
  -l app.kubernetes.io/instance=gaie-predicted-latency \
  --all-containers=true --since=15m --timestamps > /tmp/predicted-latency-epp.log
```

The committed reference artifacts for this comparison are:

- [predicted-latency-comparison.csv](../../../benchmark-comparisons/predicted-latency-comparison.csv)
- [predicted-latency-epp-evidence.txt](../../../benchmark-comparisons/predicted-latency-epp-evidence.txt)

The full raw benchmark bundles used to generate these files are intentionally kept local because
they are too large for normal git history.

## Artifact Checklist

For each comparison run, keep:

- the rendered `config.yaml`
- all `stage_*_lifecycle_metrics.json` files
- `benchmark_report_v0.2,_stage_*.yaml` files when emitted by the harness
- `summary_lifecycle_metrics.json`
- `stdout.log`
- `stderr.log`
- decode-pod logs captured during the benchmark window
- EPP logs for routed runs

For git history, prefer committing the derived comparison CSVs, evidence snippets, and doc
summaries. Keep the full raw benchmark bundles local unless they have been explicitly reduced to a
size that is safe for GitHub.

## Metric Mapping For Graphs

The comparison CSVs were generated from the benchmark bundles plus the captured logs.

| Chart metric | Source | Notes |
| --- | --- | --- |
| `Prefix Cache Hit Percent` | decode-pod logs captured during the benchmark window | This metric is **not** present in the raw benchmark bundle; it must be computed from the model-server logs |
| `ntpot p90 (ms)` | `successes.latency.normalized_time_per_output_token.p90` in `stage_*_lifecycle_metrics.json`, or `results.request_performance.aggregate.latency.normalized_time_per_output_token.p90` in `benchmark_report_v0.2` | Multiply seconds by `1000` |
| `output_tokens_per_sec` | `successes.throughput.output_tokens_per_sec`, or `results.request_performance.aggregate.throughput.output_token_rate.mean` | Already in tokens/second |
| `ttft p90 (ms)` | `successes.latency.time_to_first_token.p90`, or `results.request_performance.aggregate.latency.time_to_first_token.p90` | Multiply seconds by `1000` |
| `itl p90 (ms)` | `successes.latency.inter_token_latency.p90`, or `results.request_performance.aggregate.latency.inter_token_latency.p90` | Multiply seconds by `1000` |
| `average_input_tokens` | `successes.prompt_len.mean`, or `results.request_performance.aggregate.requests.input_length.mean` | Token count |
| `average_output_tokens` | `successes.output_len.mean`, or `results.request_performance.aggregate.requests.output_length.mean` | Token count |
| `request latency p90/p95` | `successes.latency.request_latency.p90` / `.p95`, or the equivalent `benchmark_report_v0.2` fields | Multiply seconds by `1000` if you want millisecond charts |
| `failed_requests` | `failures.count`, or `results.request_performance.aggregate.requests.failures` | Count per stage |

## Recommended Chart Layouts

### Inference scheduling shared-prefix

Use stage-based line charts keyed by offered rate:

- `Prefix Cache Hit Percent`
- `ntpot p90 (ms)`
- `output_tokens_per_sec`
- `ttft p90 (ms)`
- `itl p90 (ms)`
- `request latency p90/p95`

### Precise guide comparison

Use stage-based line charts keyed by requested rate:

- `Prefix Cache Hit Percent`
- `ttft p90 (ms)`
- `request latency p90/p95`
- `output_tokens_per_sec`

### Predicted latency

Use separate charts per workload family:

- `short_prompt_long_completion`
- `long_prompt_short_completion`
- `mixed_workload`

For each family, compare direct vs predicted-latency on:

- `ttft p90 (ms)`
- `ntpot p90 (ms)`
- `output_tokens_per_sec`
- `request latency p90/p95`

## Interpreting The Results

- A direct baseline is the control: it measures the backend deployment without gateway or EPP in the request path.
- A routed run keeps the same backend but adds gateway and scheduler behavior.
- For precise and shared-prefix comparisons, the most useful signal is the combination of routing evidence in EPP logs plus cache-hit percentages from decode logs.
- For predicted-latency, the key check is twofold:
  - EPP evidence shows the prediction-enabled scorer actually ran
  - the benchmark metrics show whether that routing policy helped or hurt the observed latency/throughput tradeoff
