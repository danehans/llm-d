# GKE Validation Tracker

This document tracks manual validation of llm-d well-lit paths on a GKE cluster.

Last updated: 2026-03-20

## Scope

This tracker covers the following work:

- GKE validation of llm-d well-lit paths
- The current integration state of:
  - `llm-d-incubation/llm-d-infra#272`
  - `llm-d/llm-d#421`
- The agentgateway-based well-lit paths tested on GKE
- Benchmark runs completed against the GKE environment
- Local overrides needed beyond stock upstream guide settings

## Environment

### Cluster

- Cluster: `llmd-agw-is-c1`
- Zone: `us-central1-b`
- GKE release channel: `REGULAR`
- GKE version: `1.34.4-gke.1047000`
- Namespace used for guide installs: `llmd`

### GPU capacity

- GPU node pool: `h100-reserved-pool`
- GPU shape: `2 x a3-highgpu-8g`
- Total GPUs: `16 x NVIDIA H100 80GB`
- GPU zone: `us-central1-b`

### Node pools used during successful runs

| Node pool | Machine type | Purpose | Notes |
| --- | --- | --- | --- |
| `h100-reserved-pool` | `a3-highgpu-8g` | GPU model serving | `8 x H100` per node, `1000 GiB` boot disk |
| `control-pool` | `e2-standard-8` | EPP control plane capacity | Added because the EPP deployment requests `4` vCPU and did not fit reliably on `e2-standard-4` nodes |
| `default-pool` | `e2-standard-4` | General cluster/system capacity | Used for baseline cluster services |

### Current live deployment

- Gateway service type: `LoadBalancer`
- Gateway address: `34.28.69.171`
- Active guide: `guides/inference-scheduling`
- Current decode replica count: `8`
- Current EPP image: `docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.2`
- Current tokenizer sidecar image: not deployed in the active inference-scheduling stack
- Current model image: `docker.io/vllm/vllm-openai:nightly-39474513f6631b1bc39a2400126bd7ff9394a774`

## Versions used in successful runs

| Component | Version / source |
| --- | --- |
| Gateway API CRDs | `v1.5.1` |
| Gateway API Inference Extension | `v1.4.0` |
| `agentgateway` | `v1.0.0` |
| `llm-d-infra` | local chart override from `llm-d-incubation/llm-d-infra#272` |
| `llm-d` | branch state from `llm-d/llm-d#421` |
| Scheduler override used in GKE guide validation | `docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.2` |
| Routing sidecar override for guides that need it | `docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.2` |

## Required deviations from stock upstream guides

These were the important changes needed to make the GKE runs reproducible.

| Area | Override / change | Why it was needed |
| --- | --- | --- |
| `llm-d-infra` source | Use `LLMD_INFRA_CHART` to point at the local PR `272` chart | The guide helmfiles otherwise consume the released chart instead of the local chart under test |
| GPU capacity | Use a dedicated `a3-highgpu-8g` node pool in `us-central1-b` | This provided a stable `16 GPU` footprint for full-guide testing |
| CPU capacity | Add `control-pool` with `e2-standard-8` nodes | EPP requests `4` vCPU and did not fit well on `e2-standard-4` nodes once system reservations were considered |
| Precise guide GAIE values | Patch `guides/precise-prefix-cache-aware/gaie-kv-events/values.yaml` for GAIE `v1.4.0` | The stock values needed a compatibility update for the newer GAIE chart |
| Precise guide model image | Override the model image away from `ghcr.io/llm-d/llm-d-cuda:v0.5.1` when validating precise cache hits | The older vLLM KV event format did not interoperate with the newer scheduler-side decoder |
| Benchmarking on GKE | Enable Filestore CSI and use an RWX PVC | The benchmark harness requires shared writable storage for results |

## Well-Lit Path Validation Matrix

### E2E

| Well-lit path | Status | Infra fit for current cluster | What was validated | Notes |
| --- | --- | --- | --- | --- |
| Inference Scheduling | Pass | Yes | Full guide on GKE with `agentgateway`, `8/8` decode replicas, smoke tests passed | Untuned H100 path worked cleanly on the current `a3-highgpu-8g` pool |
| Precise Prefix Cache Aware Routing | Pass with override | Yes | Guide installed on the same GKE cluster, smoke tests passed, precise scorer revalidated | Base smoke passed on `ghcr.io/llm-d/llm-d-cuda:v0.5.1`, but the precise scorer issue required a newer model image to validate cache hits |
| Prefill / Decode Disaggregation | Blocked | No | Not attempted on this cluster | Current cluster shape is `a3-highgpu-8g` and does not satisfy the RDMA-oriented GKE requirements documented for the guide |
| Workload Autoscaling | Not started | Yes | Not yet run | This layers on the inference-scheduling path and is compatible with the current cluster from a GPU-capacity perspective |
| Tiered Prefix Cache | Not started | Yes, with storage work | Not yet run | GPU fit is fine; storage/backend selection still needs to be decided |
| Wide Expert Parallelism | Blocked | No | Not attempted on this cluster | Requires RDMA-capable hardware and a larger accelerator footprint than `2 x a3-highgpu-8g` |

### Benchmark

| Base path | Profile | Status | Scale | Notes |
| --- | --- | --- | --- | --- |
| Inference Scheduling | `guidellm` `rate_comparison` | Pass | `2` decode replicas | Completed successfully against the `agentgateway` path |
| Inference Scheduling | `guidellm` `rate_comparison` | Pass | `4` decode replicas | Completed successfully after scaling decode from `2` to `4` |
| Inference Scheduling | `inference-perf` `shared_prefix_synthetic` | Pass | `8` decode replicas | Control benchmark completed successfully on the same cluster and model image used for the precise comparison |
| Precise Prefix Cache Aware Routing | `guidellm` `rate_comparison` | Pass | `8` decode replicas | Harness smoke test completed successfully against the precise gateway |
| Precise Prefix Cache Aware Routing | `inference-perf` `sanity_random` | Pass | `8` decode replicas | Random-traffic baseline completed successfully |
| Precise Prefix Cache Aware Routing | `inference-perf` `shared_prefix_synthetic` | Pass | `8` decode replicas | Main precise benchmark completed successfully with shared-prefix traffic and routing evidence |
| Prefill / Decode Disaggregation | None | Blocked | N/A | Blocked by current GKE hardware mismatch |

### Precise benchmark summary

The following table is the tight summary intended for later doc/report generation. Full raw artifacts remain in the local benchmark result bundles.

| Run | Stage / offered rate | Failures | Median latency | p95 latency | Median TTFT | p95 TTFT | Mean total throughput | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Precise `guidellm` | `1 rps` | `0` | `0.7s` | `0.7s` | `46.2 ms` | `60.0 ms` | `101.1 tok/s` | Small harness-validation workload |
| Precise `guidellm` | `5 rps` | `0` | `0.7s` | `0.7s` | `35.7 ms` | `41.7 ms` | `498.2 tok/s` | Small harness-validation workload |
| Precise `sanity_random` | `1 rps` | `0` | `0.714s` | `0.913s` | `36.0 ms` | `51.4 ms` | `92.9 tok/s` | Random-traffic baseline using `inference-perf` |
| Precise `shared_prefix_synthetic` | `2 rps` | `0` | `3.707s` | `3.832s` | `103.3 ms` | `203.2 ms` | `5006.5 tok/s` | First stage of the shared-prefix benchmark |
| Precise `shared_prefix_synthetic` | `20 rps` | `0` | `3.937s` | `4.176s` | `105.2 ms` | `165.6 ms` | `50086.1 tok/s` | Final stage of the shared-prefix benchmark |

### Benchmark artifacts

Committed result bundles captured from the precise and inference-scheduling benchmark runs:

- [`precise-is-guidellm-results-8pods`](../../../precise-is-guidellm-results-8pods)
- [`precise-is-random-results-8pods`](../../../precise-is-random-results-8pods)
- [`precise-is-shared-prefix-results-8pods`](../../../precise-is-shared-prefix-results-8pods)
- [`inference-scheduling-shared-prefix-results-8pods`](../../../inference-scheduling-shared-prefix-results-8pods)

The shared-prefix result bundles include chart-ready outputs, for example:

- `analysis/latency_vs_qps.png`
- `analysis/throughput_vs_qps.png`
- `analysis/throughput_vs_latency.png`

These bundles are the source material for the later benchmark subsection planned for the inference-routing section of the `agentgateway.dev` docs.

The very large raw `per_request_lifecycle_metrics.json` traces from the shared-prefix runs are intentionally kept out of git due to GitHub file-size limits. The committed bundles retain the summary reports, plots, configs, and logs needed for doc work.

### Precise benchmark routing evidence

The shared-prefix benchmark produced positive routing evidence beyond simple benchmark completion:

- EPP logs showed non-empty precise scorer hits during the run, for example `Got endpoint scores {"10.72.1.13":37}`
- The same EPP log window showed the repeated request being routed back to `10.72.1.13:8000`
- Matching decode-pod logs showed sustained prefix cache hit rates after the run in the `91.3%` to `98.2%` range

### Shared-prefix comparison

This is the compact apples-to-apples comparison between:

- `guides/precise-prefix-cache-aware`
- `guides/inference-scheduling`

Both runs used:

- the same GKE cluster
- the same `8` decode replica shape
- the same model `Qwen/Qwen3-32B`
- the same model image `docker.io/vllm/vllm-openai:nightly-39474513f6631b1bc39a2400126bd7ff9394a774`
- the same benchmark template `guides/benchmark/inference_scheduling_shared_prefix_template.yaml`

| Dimension | Precise | Inference-scheduling control | Takeaway |
| --- | --- | --- | --- |
| Endpoint affinity | Direct EPP evidence: `Got endpoint scores {"10.72.1.13":37}` and repeated request routed back to `10.72.1.13:8000` | Control run completed successfully, but the captured EPP logs did not provide equally strong endpoint-specific cache-hit evidence | Precise has the clearest proof of routing to the cached endpoint |
| Prefix cache hit rate | `91.3%` to `98.2%` in decode-pod logs | `95.3%` to `96.5%` in decode-pod logs | Both paths achieved very high cache-hit rates in this workload |
| Throughput at saturation (`20 rps`) | `50086.1 tok/s` mean total throughput | `50205.9 tok/s` mean total throughput | Effectively tied |
| Tail request latency at saturation (`20 rps`) | `4.176s` p95 request latency | `4.238s` p95 request latency | Slight edge to precise |
| Tail request latency at entry stage (`2 rps`) | `3.832s` p95 request latency | `3.884s` p95 request latency | Slight edge to precise |
| TTFT tail at saturation (`20 rps`) | `165.6 ms` p95 TTFT | `95.0 ms` p95 TTFT | Control was better on TTFT at the highest-rate stage |
| TTFT tail at entry stage (`2 rps`) | `203.2 ms` p95 TTFT | `275.0 ms` p95 TTFT | Precise was better on TTFT at the lowest-rate stage |

The main conclusion from this comparison is:

- precise showed the strongest observable endpoint-affinity behavior
- throughput was effectively the same
- request-latency tails slightly favored precise
- TTFT did not show a stable precise advantage across stages

## Inference Scheduling Notes

The following was true for the successful inference-scheduling run:

- The H100 node pool came up cleanly with `2 x a3-highgpu-8g`
- The guide worked without the A100-specific tuning that was previously required
- `8/8` decode replicas became ready
- Public gateway smoke tests passed for:
  - `/v1/models`
  - `/v1/completions`
  - `/v1/chat/completions`

This is the current reference point for a fully working GKE `agentgateway` well-lit path on the current cluster.

## Precise Prefix Cache Notes

### What failed with the older model image

Using `ghcr.io/llm-d/llm-d-cuda:v0.5.1`:

- Basic smoke tests passed
- The precise scorer did not register cache hits
- EPP logs showed KV event decode failures such as:
  - `Failed to parse message`
  - `failed to decode vLLM event`
  - `failed to decode BlockStored event`

### What fixed the issue during validation

Using `docker.io/vllm/vllm-openai:nightly-39474513f6631b1bc39a2400126bd7ff9394a774`:

- Smoke tests still passed
- EPP `precise-prefix-cache-scorer` started returning non-empty endpoint scores
- Repeated long-prompt requests were routed back to the cached endpoint
- Matching decode-pod logs showed non-zero prefix cache hit rates
- The earlier KV event decode failures were absent in the same log window

### Current validation state

- The precise guide is currently left running at `8` decode replicas
- Smoke tests passed again after restoring full guide scale
- The precise path has now also been benchmarked successfully with the intelligent-scheduling templates against the same `8`-replica deployment

## Paths this cluster does and does not support

### Good fits for the current cluster

- `guides/inference-scheduling`
- `guides/precise-prefix-cache-aware`
- `guides/workload-autoscaling`
- `guides/tiered-prefix-cache` when paired with the inference-scheduling family of guides

### Not a fit for the current cluster

- `guides/pd-disaggregation`
- `guides/wide-ep-lws`

The common reason is RDMA-oriented infrastructure requirements that are not met by the current `a3-highgpu-8g` cluster shape.

## Suggested next steps

1. Scale the precise deployment back to `8` and revalidate precise cache hits at full guide scale.
2. Use the same GKE cluster to test `guides/workload-autoscaling` with `agentgateway`.
3. Decide whether `guides/tiered-prefix-cache` should be validated next with local disk, CPU memory, or shared storage.
4. If P/D or Wide-EP validation is needed, provision a new RDMA-capable GKE environment on hardware aligned with those guides.
