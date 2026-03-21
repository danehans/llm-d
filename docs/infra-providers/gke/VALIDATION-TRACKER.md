# GKE Validation Tracker

Last updated: 2026-03-21

This document is the index for the GKE validation and benchmarking package captured on the
`codex/gke-well-lit-validation` branch. The GKE cluster used for these runs has been torn down.
This tracker now records the historical environment, the final validation status, and the
committed artifacts that back the comparison work.

For a reproduction-oriented runbook, see [GKE handoff package](./HANDOFF.md).

## Scope

This package covers:

- end-to-end validation of the supported GKE well-lit paths we were able to exercise
- direct Kubernetes Service baselines for selected well-lit paths
- `agentgateway` + EPP comparison runs for those same paths
- prediction-based scheduling validation on top of the precise backend
- exploratory workload-autoscaling and tiered-prefix-cache runs
- final teardown verification for the historical GKE environment

## Historical Environment

### Cluster shape used during successful runs

- historical cluster name: `llmd-agw-is-c1`
- zone: `us-central1-b`
- GKE release channel: `REGULAR`
- GKE version: `1.34.4-gke.1047000`
- namespace used for guide installs: `llmd`

### Node pools used during successful runs

| Node pool | Machine type | Purpose | Notes |
| --- | --- | --- | --- |
| `h100-reserved-pool` | `a3-highgpu-8g` | GPU model serving | `2` nodes, `16 x H100 80GB` total |
| `control-pool` | `e2-standard-8` | EPP/control-plane capacity | Added because the EPP deployment requested `4` vCPU |
| `default-pool` | `e2-standard-4` | General cluster/system capacity | Used for baseline system workloads |

### Versions and overrides used in successful runs

| Component | Version / source |
| --- | --- |
| Gateway API CRDs | `v1.5.1` |
| Gateway API Inference Extension | `v1.4.0` |
| `agentgateway` | `v1.0.0` |
| `llm-d-infra` | local chart override from `llm-d-incubation/llm-d-infra#272` |
| `llm-d` | branch state from `llm-d/llm-d#421` |
| Scheduler image override | `docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.2` |
| Routing sidecar override | `docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.2` |
| Precise validation model image override | `docker.io/vllm/vllm-openai:nightly-39474513f6631b1bc39a2400126bd7ff9394a774` |

### GKE-specific deviations from stock upstream guides

| Area | Override / change | Why it was needed |
| --- | --- | --- |
| `llm-d-infra` source | Use `LLMD_INFRA_CHART` to point at the local PR `272` chart | Guide helmfiles otherwise consume the released chart |
| CPU capacity | Add `control-pool` with `e2-standard-8` nodes | EPP requests `4` vCPU and did not fit reliably on `e2-standard-4` nodes |
| Precise guide model image | Override away from `ghcr.io/llm-d/llm-d-cuda:v0.5.1` | Older vLLM KV-event format did not interoperate with the newer scheduler-side decoder |
| Benchmark storage | Use a Filestore-backed RWX PVC | The benchmark harness needs shared writable storage |
| Benchmark runner on macOS | Install GNU `timeout`; be prepared to tune the downloaded `run_only.sh` copy if launcher readiness or resource requests are too aggressive for your cluster | This was an operational requirement during the original runs and is not encoded in the repo |

## Final Infrastructure State

The historical GKE environment has been cleaned up.

- cluster deleted
- node pools deleted
- Filestore-backed benchmark storage deleted
- public load balancers removed
- the associated future reservation window expired, and the auto-created active reservation disappeared

This tracker is therefore a historical record plus a handoff package, not a description of a live environment.

## E2E Validation Matrix

| Well-lit path | Status | Outcome | Notes |
| --- | --- | --- | --- |
| `guides/inference-scheduling` | Pass | Full guide validated with `agentgateway`, `8/8` decode replicas, smoke tests passed | Untuned H100 path worked cleanly on `2 x a3-highgpu-8g` |
| `guides/precise-prefix-cache-aware` | Pass with model image override | Full guide validated with `agentgateway`; precise scorer revalidated after model image override | Base smoke passed on `ghcr.io/llm-d/llm-d-cuda:v0.5.1`, but real precise cache-hit validation required a newer vLLM image |
| `guides/predicted-latency-based-scheduling` | Pass | Second `InferencePool` installed successfully on top of the precise backend; header-routed path worked end to end | Functional validation passed even though the direct baseline outperformed the predicted-latency path in these runs |
| `guides/workload-autoscaling` | Pass with caveat | E2E smoke tests passed | The HPA never scaled because the external metric remained `0` during the benchmark run |
| `guides/tiered-prefix-cache` paired with inference-scheduling | Partial | Smoke tests passed | High-cache benchmark runs triggered model pod restarts and vLLM failures under load |
| `guides/pd-disaggregation` | Blocked | Not attempted | Current cluster shape did not satisfy the RDMA-oriented GKE requirements |
| `guides/wide-ep-lws` | Blocked | Not attempted | Required RDMA-capable hardware and a larger accelerator footprint |

## Comparison-Ready Benchmark Sets

These are the artifact sets intended for later charting and website work.

| Comparison | Baseline flow | Routed flow | Template | Published data | Local-only raw artifacts |
| --- | --- | --- | --- | --- | --- |
| Inference scheduling shared-prefix | direct Kubernetes Service to decode pods | `agentgateway` + EPP through the inference gateway | [`inference_scheduling_shared_prefix_template.yaml`](../../../guides/benchmark/inference_scheduling_shared_prefix_template.yaml) | [`shared-prefix-comparison.csv`](../../../benchmark-comparisons/shared-prefix-comparison.csv) | kept local due to benchmark bundle size |
| Precise guide comparison | direct Kubernetes Service to decode pods | `agentgateway` + EPP through the precise inference gateway | [`precise_guide_template.yaml`](../../../guides/benchmark/precise_guide_template.yaml) | [`precise-guide-comparison.csv`](../../../benchmark-comparisons/precise-guide-comparison.csv) | kept local due to benchmark bundle size |
| Predicted-latency comparison | direct Kubernetes Service to decode pods | predicted-latency profile through the gateway using request headers | [`predicted_latency_template.yaml`](../../../guides/benchmark/predicted_latency_template.yaml) | [`predicted-latency-comparison.csv`](../../../benchmark-comparisons/predicted-latency-comparison.csv), [`predicted-latency-epp-evidence.txt`](../../../benchmark-comparisons/predicted-latency-epp-evidence.txt) | kept local due to benchmark bundle size |

## Exploratory Benchmark Sets

These runs were useful during validation, but they are not the primary comparison datasets.

| Area | Artifact(s) | Outcome |
| --- | --- | --- |
| Earlier precise exploratory runs | [`precise-is-guidellm-results-8pods`](../../../precise-is-guidellm-results-8pods), [`precise-is-random-results-8pods`](../../../precise-is-random-results-8pods), [`precise-is-shared-prefix-results-8pods`](../../../precise-is-shared-prefix-results-8pods) | Helped validate the precise path and the KV-event fix before we built the final comparison datasets |
| Earlier inference-scheduling exploratory run | [`inference-scheduling-shared-prefix-results-8pods`](../../../inference-scheduling-shared-prefix-results-8pods) | Earlier routed-only shared-prefix run before the direct-baseline package was added |
| Workload autoscaling | raw benchmark artifacts kept local | Benchmark completed, but the HPA stayed fixed at `2` replicas because the external metric stayed `0` |
| Tiered prefix cache | raw benchmark artifacts kept local | Smoke passed, but high-cache stress runs exposed vLLM failures and pod restarts under load |

## Headline Findings

### Direct baseline vs `agentgateway` + EPP

- For inference scheduling with shared-prefix traffic, the routed path produced higher measured prefix-cache hit percentages than the direct baseline and remained comparable on throughput and tail latency. See [`shared-prefix-comparison.csv`](../../../benchmark-comparisons/shared-prefix-comparison.csv).
- For the precise guide workload, the routed path materially improved TTFT and request-latency tails relative to the direct baseline on the stages captured in [`precise-guide-comparison.csv`](../../../benchmark-comparisons/precise-guide-comparison.csv).
- For prediction-based scheduling, the routed path was functionally correct and emitted the expected predictor evidence, but the direct baseline still outperformed it on these runs. See [`predicted-latency-comparison.csv`](../../../benchmark-comparisons/predicted-latency-comparison.csv).

### Path-specific caveats

- Workload autoscaling needs follow-up investigation before it can be presented as a scaling success story on GKE because the external metric never rose above `0`.
- Tiered prefix cache is functionally interesting but not ready to present as a stable benchmark result from this environment due to the model-server failures under high-cache load.

## How To Use This Package

Use this tracker as the table of contents:

1. Read [GKE handoff package](./HANDOFF.md) for the reproduction flow.
2. Use the comparison CSVs above for charting work. The underlying benchmark bundles are intentionally kept local because they are too large for normal git history.
3. Use the benchmark methodology section in [guides/benchmark/README.md](../../../guides/benchmark/README.md) to understand how the chart metrics map back to the raw result files.
