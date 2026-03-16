# GKE + agentgateway scripted workflow for inference-scheduling

These scripts package the GKE Standard + `agentgateway` workflow we exercised
for the inference-scheduling guide. They are intentionally opinionated around:

- GKE Standard
- `agentgateway`
- H100 capacity managed through either:
  - queued `A3 High` capacity on `a3-highgpu-2g`
  - reservation-backed `A3 High` capacity on `a3-highgpu-8g`
- `RELEASE_NAME_POSTFIX=is`
- namespace `llmd`

The scripts are split so the common workflows stay explicit:

- build from scratch
- park or resume cloud infrastructure
- scale well-lit path components
- request H100 capacity intentionally before scaling the decode deployment

## Capacity modes

Set `H100_CAPACITY_MODE` to choose the H100 strategy:

- `queued`
  - the existing `ProvisioningRequest`-based `a3-highgpu-2g` path
- `reservation`
  - a reservation-backed `a3-highgpu-8g` path that consumes a specific Compute Engine reservation

Reservation mode is meant for predictable scale-out, but it has stricter cloud
requirements than the queued flow:

- use a reservable shape such as `a3-highgpu-8g`
- create a future reservation first
- the current Google Cloud future-reservation guidance for these GPU shapes has
  a minimum lead time of roughly `87 hours`

## Environment

At minimum, export:

```bash
export PROJECT_ID=solo-oss
```

Common optional overrides:

```bash
export CLUSTER_NAME=llmd-agw-is-c1
export CLUSTER_ZONE=us-central1-f
export NODE_LOCATION=us-central1-b
export NAMESPACE=llmd
export RELEASE_NAME_POSTFIX=is
export LLMD_INFRA_CHART=/path/to/llm-d-infra/charts/llm-d-infra
# Optional:
# export H100_CAPACITY_MODE=queued
```

If the Hugging Face secret does not already exist in the target namespace, the
install script looks for:

1. `HF_TOKEN`
2. `~/.cache/huggingface/token`

## Scripts

- `cluster.sh`
  - `create`: create the cluster and zero-node queued H100 pool if absent
  - `delete`: delete the cluster
  - `status`: show cluster, node pools, and nodes
- `install-stack.sh`
  - install Gateway API + GAIE CRDs, `agentgateway`, monitoring, the llm-d
    stack, and the customized `HTTPRoute`
  - installs decode at `0` replicas so H100 capacity can be checked first
  - applies the queued-node toleration needed for `cloud.google.com/gke-queued`
- `destroy-stack.sh`
  - remove the llm-d stack, monitoring, and `agentgateway`
- `scale-cloud-infra.sh`
  - `cpu`: resize the default CPU node pool
  - `ensure-queued`: recreate the queued H100 pool if needed
  - `ensure-reserved`: recreate the reservation-backed H100 pool if needed
  - `ensure-h100`: ensure the active H100 capacity pool for the current mode
  - `status`: show pools and nodes
- `queue-capacity.sh`
  - create a `PodTemplate` plus `ProvisioningRequest` for the queued H100 pool
  - supports `watch` and `recreate` with timeout-based monitoring
  - defaults to a 30-minute wait window, override with `WAIT_TIMEOUT_SECONDS`
  - supports `race` across multiple zone/pool candidates, canceling the losers
- `scale-components.sh`
  - scale decode, EPP, and gateway deployments in place
  - refuses to scale decode up unless there is live, unexpired queued capacity
- `scale-decode-with-capacity.sh`
  - requests queued H100 capacity for the additional decode replicas
  - optionally races requests across candidate zones/pools
  - waits for the winning H100 pool to have enough ready nodes before scaling
  - in reservation mode, scales decode first and then watches the reservation-backed node pool
- `reservation-capacity.sh`
  - `check-permissions`: verify the active `gcloud` account has the required
    reservation-mode IAM permissions on the project
  - `advice`: ask Google Cloud for a future-reservation time window and zone
  - `create-future`: create a future reservation request
  - `describe-future`: inspect the future reservation request
  - `describe-reservation`: inspect the active reservation created from it
  - `ensure-pool`: create the reservation-backed node pool that consumes the reservation
  - `status`: summarize the reservation and pool state
- `smoke-test.sh`
  - creates or reuses an in-cluster `curl` client pod
  - runs `/v1/models`, `/v1/completions`, and `/v1/chat/completions`
    against the gateway service without requiring local curl or port-forwarding
- benchmarking uses the generic [guides/benchmark/scripts/benchmark.sh](../../../benchmark/scripts/benchmark.sh)
  flow after the stack is ready
- `build-from-scratch.sh`
  - orchestration wrapper that ties the cluster, install, queue, and initial
    decode scale-up steps together

## Cold start to 2 decode replicas

```bash
export PROJECT_ID=solo-oss
export LLMD_INFRA_CHART=/path/to/llm-d-infra/charts/llm-d-infra
INITIAL_DECODE_REPLICAS=2 \
guides/inference-scheduling/scripts/gke-agentgateway/build-from-scratch.sh
```

## Scale from 2 decode replicas to 8

Scale decode from 2 to 8 with queued-capacity orchestration:

```bash
export PROJECT_ID=solo-oss
TARGET_DECODE_REPLICAS=8 \
guides/inference-scheduling/scripts/gke-agentgateway/scale-decode-with-capacity.sh
```

## Reservation-backed path

Example reservation planning flow:

```bash
export PROJECT_ID=solo-oss
export H100_CAPACITY_MODE=reservation
export H100_RESERVED_ZONE=us-central1-b
export H100_RESERVED_MACHINE_TYPE=a3-highgpu-8g
export H100_RESERVED_RESERVATION_NAME=llmd-h100-reservation
export H100_FUTURE_RESERVATION_NAME=llmd-h100-future
export H100_FUTURE_RESERVATION_VM_COUNT=2

guides/inference-scheduling/scripts/gke-agentgateway/reservation-capacity.sh check-permissions
guides/inference-scheduling/scripts/gke-agentgateway/reservation-capacity.sh advice
```

Reservation mode requires these project permissions before planning or creating
future reservations:

- `compute.advice.calendarMode`
- `compute.futureReservations.create`
- `compute.reservations.create`

The script now checks those permissions up front:

- `check-permissions` verifies all three
- `advice` verifies `compute.advice.calendarMode`
- `create-future` verifies `compute.futureReservations.create` and
  `compute.reservations.create`

Once you have a usable window, create the future reservation:

```bash
export FUTURE_START_TIME=2026-03-20T16:00:00Z
export FUTURE_DURATION=24h
guides/inference-scheduling/scripts/gke-agentgateway/reservation-capacity.sh create-future
```

For GPU calendar-mode reservations, the script now enforces the Google Cloud
requirements we tripped over during testing:

- minimum duration: `24h`
- deployment type: `DENSE`

`FUTURE_DURATION` can be written as `24h`, `1d`, or raw seconds.

After the reservation is active, create the reservation-backed node pool and
use the same scale wrapper:

```bash
guides/inference-scheduling/scripts/gke-agentgateway/reservation-capacity.sh ensure-pool
TARGET_DECODE_REPLICAS=8 \
guides/inference-scheduling/scripts/gke-agentgateway/scale-decode-with-capacity.sh
```

Run smoke tests from an in-cluster curl client:

```bash
export PROJECT_ID=solo-oss
guides/inference-scheduling/scripts/gke-agentgateway/smoke-test.sh all
```

If you only want to watch an existing queued request:

```bash
export PROJECT_ID=solo-oss
REQUEST_NAME=is-scaleout-6x2 \
guides/inference-scheduling/scripts/gke-agentgateway/queue-capacity.sh watch
```

## Multi-zone queued-capacity race

Set candidate pools in the format:

```text
pool|zone|machine_type|gpu_type|gpu_count|optional_max_nodes;...
```

Example:

```bash
export PROJECT_ID=solo-oss
export QUEUE_CANDIDATES='a3-uc1a|us-central1-a|a3-highgpu-2g|nvidia-h100-80gb|2|8;a3-uc1b|us-central1-b|a3-highgpu-2g|nvidia-h100-80gb|2|8;a3-uc1c|us-central1-c|a3-highgpu-2g|nvidia-h100-80gb|2|8'
REQUEST_NAME=is-bringup-2x2 \
POD_COUNT=2 \
WINNER_ENV_FILE=/tmp/bringup-winner.env \
guides/inference-scheduling/scripts/gke-agentgateway/queue-capacity.sh race
```

The first candidate request to reach `Provisioned=True` wins. The script deletes
the losing requests and writes the winner to `WINNER_ENV_FILE` if set.

## Park the cluster at zero worker nodes

Remove the workload stack first:

```bash
export PROJECT_ID=solo-oss
guides/inference-scheduling/scripts/gke-agentgateway/destroy-stack.sh
```

Then resize the default CPU pool to zero:

```bash
export PROJECT_ID=solo-oss
CPU_NODES=0 \
guides/inference-scheduling/scripts/gke-agentgateway/scale-cloud-infra.sh cpu
```

This leaves the queued H100 pool definition in place without holding worker-node
capacity. The GKE control plane still exists, so cluster charges continue until
you delete the cluster.

## Follow-up improvements

These are good next improvements for the scripted workflow:

1. Tag all created Google Cloud resources so they can be discovered and managed
   as one logical llm-d inference-scheduling test stack.
2. Add a garbage-collection flow that periodically checks for stale resources,
   reports either a clean result or the stale resources it found, and asks for
   confirmation before deleting anything.
