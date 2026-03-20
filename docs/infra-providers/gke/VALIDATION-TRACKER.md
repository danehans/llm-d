# GKE Reservation-Backed Validation Tracker

This document tracks manual validation of llm-d well-lit paths on a reservation-backed GKE cluster.

Last updated: 2026-03-20

## Scope

This tracker covers the following work:

- Reservation-backed GKE validation in project `solo-oss`
- The current integration state of:
  - `llm-d-incubation/llm-d-infra#272`
  - `llm-d/llm-d#421`
- The agentgateway-based well-lit paths tested on GKE
- Benchmark runs completed against the GKE environment
- Local overrides needed beyond stock upstream guide settings

## Environment

### Cluster

- Project: `solo-oss`
- Cluster: `llmd-agw-is-c1`
- Zone: `us-central1-b`
- GKE release channel: `REGULAR`
- GKE version: `1.34.4-gke.1047000`
- Namespace used for guide installs: `llmd`

### Reservation-backed GPU capacity

- Future reservation: `llmd-h100-future`
- Reservation: `llmd-h100-reservation`
- Reservation zone: `us-central1-b`
- Reservation status: `READY`
- Reservation mode: specific reservation required
- Reserved shape: `2 x a3-highgpu-8g`
- Total reserved GPUs: `16 x NVIDIA H100 80GB`

### Node pools used during successful runs

| Node pool | Machine type | Purpose | Notes |
| --- | --- | --- | --- |
| `h100-reserved-pool` | `a3-highgpu-8g` | GPU model serving | Reservation-backed pool, `8 x H100` per node, `1000 GiB` boot disk |
| `control-pool` | `e2-standard-8` | EPP control plane capacity | Added because the EPP deployment requests `4` vCPU and did not fit reliably on `e2-standard-4` nodes |
| `default-pool` | `e2-standard-4` | General cluster/system capacity | Used for baseline cluster services |

### Current live precise deployment

- Gateway service type: `LoadBalancer`
- Gateway address: `34.55.152.96`
- Active guide: `guides/precise-prefix-cache-aware`
- Current decode replica count: `2`
- Current EPP image: `docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.2`
- Current tokenizer sidecar image: `ghcr.io/llm-d/llm-d-uds-tokenizer:v0.6.0`
- Current model image: `docker.io/vllm/vllm-openai:nightly-39474513f6631b1bc39a2400126bd7ff9394a774`

## Versions used in successful runs

| Component | Version / source |
| --- | --- |
| Gateway API CRDs | `v1.5.1` |
| Gateway API Inference Extension | `v1.4.0-rc.3` |
| `agentgateway` | `v1.0.0` |
| `llm-d-infra` | local chart override from `llm-d-incubation/llm-d-infra#272` |
| `llm-d` | branch state from `llm-d/llm-d#421` |
| Scheduler override used in GKE guide validation | `docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.2` |
| Routing sidecar override for guides that need it | `docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.2` |

## Required deviations from stock upstream guides

These were the important changes needed to make the reservation-backed GKE runs reproducible.

| Area | Override / change | Why it was needed |
| --- | --- | --- |
| `llm-d-infra` source | Use `LLMD_INFRA_CHART` to point at the local PR `272` chart | The guide helmfiles otherwise consume the released chart instead of the local chart under test |
| GPU capacity | Use a reservation-backed `a3-highgpu-8g` node pool in `us-central1-b` | The queued / flex-start path was not reliable enough for predictable `16 GPU` bring-up |
| CPU capacity | Add `control-pool` with `e2-standard-8` nodes | EPP requests `4` vCPU and did not fit well on `e2-standard-4` nodes once system reservations were considered |
| Precise guide GAIE values | Patch `guides/precise-prefix-cache-aware/gaie-kv-events/values.yaml` for GAIE `v1.4.0-rc.3` | The stock values needed a compatibility update for the newer GAIE chart |
| Precise guide model image | Override the model image away from `ghcr.io/llm-d/llm-d-cuda:v0.5.1` when validating precise cache hits | The older vLLM KV event format did not interoperate with the newer scheduler-side decoder |
| Benchmarking on GKE | Enable Filestore CSI and use an RWX PVC | The benchmark harness requires shared writable storage for results |

## Well-Lit Path Validation Matrix

### E2E

| Well-lit path | Status | Infra fit for current reservation | What was validated | Notes |
| --- | --- | --- | --- | --- |
| Inference Scheduling | Pass | Yes | Full guide on GKE with `agentgateway`, `8/8` decode replicas, smoke tests passed | Untuned H100 path worked cleanly on the reservation-backed `a3-highgpu-8g` pool |
| Precise Prefix Cache Aware Routing | Pass with override | Yes | Guide installed on the same reservation-backed cluster, smoke tests passed, precise scorer revalidated | Base smoke passed on `ghcr.io/llm-d/llm-d-cuda:v0.5.1`, but the precise scorer issue required a newer model image to validate cache hits |
| Prefill / Decode Disaggregation | Blocked | No | Not attempted on this reservation | Current reservation is `a3-highgpu-8g` and does not satisfy the RDMA-oriented GKE requirements documented for the guide |
| Workload Autoscaling | Not started | Yes | Not yet run | This layers on the inference-scheduling path and is compatible with the current reservation from a GPU-capacity perspective |
| Tiered Prefix Cache | Not started | Yes, with storage work | Not yet run | GPU fit is fine; storage/backend selection still needs to be decided |
| Wide Expert Parallelism | Blocked | No | Not attempted on this reservation | Requires RDMA-capable hardware and a larger accelerator footprint than `2 x a3-highgpu-8g` |

### Benchmark

| Base path | Profile | Status | Scale | Notes |
| --- | --- | --- | --- | --- |
| Inference Scheduling | `guidellm` `rate_comparison` | Pass | `2` decode replicas | Completed successfully against the `agentgateway` path |
| Inference Scheduling | `guidellm` `rate_comparison` | Pass | `4` decode replicas | Completed successfully after scaling decode from `2` to `4` |
| Precise Prefix Cache Aware Routing | None yet | Not run | N/A | Benchmarking has not been rerun yet on the precise path |
| Prefill / Decode Disaggregation | None | Blocked | N/A | Blocked by current GKE hardware mismatch |

## Inference Scheduling Notes

The following was true for the successful inference-scheduling run:

- Reservation-backed H100 node pool came up cleanly with `2 x a3-highgpu-8g`
- The guide worked without the A100-specific tuning that was previously required
- `8/8` decode replicas became ready
- Public gateway smoke tests passed for:
  - `/v1/models`
  - `/v1/completions`
  - `/v1/chat/completions`

This is the current reference point for a fully working GKE `agentgateway` well-lit path on the reservation-backed cluster.

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

- The precise guide is currently left running at `2` decode replicas
- The scale-down to `2` was intentional to speed up rollout and keep the nightly-image validation focused
- The next logical precise follow-up is to scale back to `8` and confirm the same behavior at full guide scale

## Paths this reservation does and does not support

### Good fits for the current reservation

- `guides/inference-scheduling`
- `guides/precise-prefix-cache-aware`
- `guides/workload-autoscaling`
- `guides/tiered-prefix-cache` when paired with the inference-scheduling family of guides

### Not a fit for the current reservation

- `guides/pd-disaggregation`
- `guides/wide-ep-lws`

The common reason is RDMA-oriented infrastructure requirements that are not met by the current `a3-highgpu-8g` reservation.

## Suggested next steps

1. Scale the precise deployment back to `8` and revalidate precise cache hits at full guide scale.
2. Use the same reservation-backed cluster to test `guides/workload-autoscaling` with `agentgateway`.
3. Decide whether `guides/tiered-prefix-cache` should be validated next with local disk, CPU memory, or shared storage.
4. If P/D or Wide-EP validation is needed, acquire a new RDMA-capable reservation on hardware aligned with those guides.
