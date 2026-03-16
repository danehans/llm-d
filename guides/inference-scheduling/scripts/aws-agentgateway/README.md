# AWS + agentgateway scripted workflow for inference-scheduling

These scripts package an AWS/EKS + `agentgateway` workflow for the
inference-scheduling guide. They are modeled after the existing GKE scripts,
but adapted to AWS terminology and capacity behavior.

Current support is focused on:

- EKS
- `agentgateway`
- `RELEASE_NAME_POSTFIX=is`
- namespace `llmd`
- GPU capacity modes:
  - `on-demand`
  - `odcr` for immediate-use On-Demand Capacity Reservations

Planned follow-on modes:

- `capacity-block` for future-dated guaranteed GPU capacity

The current on-demand path keeps GPU worker cost low until we need it:

- create the EKS control plane
- create a small CPU/system nodegroup
- create zero-size GPU managed nodegroups for candidate AZs
- race the GPU nodegroups by scaling them up and waiting for real nodes to
  become `Ready`
- keep the winner and scale the losers back to zero

## Environment

At minimum, export:

```bash
export AWS_PROFILE=552234177002_Eng-FE-Restricted
export AWS_REGION=us-west-2
```

Common optional overrides:

```bash
export CLUSTER_NAME=llmd-agw-is-aws
export NAMESPACE=llmd
export RELEASE_NAME_POSTFIX=is
export GPU_CAPACITY_MODE=on-demand
export GPU_INSTANCE_TYPE=p5.48xlarge
export GPU_CANDIDATE_AZS=us-west-2a,us-west-2b,us-west-2c
export LLMD_INFRA_CHART=/path/to/llm-d-infra/charts/llm-d-infra
```

ODCR-specific optional overrides:

```bash
export GPU_CAPACITY_MODE=odcr
export ODCR_INSTANCE_MATCH_CRITERIA=open
export ODCR_END_DATE_TYPE=unlimited
```

If the Hugging Face secret does not already exist in the target namespace, the
install script looks for:

1. `HF_TOKEN`
2. `~/.cache/huggingface/token`

## Scripts

- `cluster.sh`
  - `create`: create the EKS cluster and small CPU/system nodegroup
  - `delete`: delete the cluster and nodegroups
  - `status`: show cluster, nodegroups, and nodes
- `capacity.sh`
  - `discover-candidates`: list candidate AZs for the configured GPU instance
  - `ensure-nodegroups`: create zero-size GPU nodegroups for those AZs
  - `race`:
    - `on-demand`: scale the candidate GPU nodegroups up and keep the first one
      that reaches the requested ready-node count
    - `odcr`: create immediate-use capacity reservations across the candidate
      AZs, keep the first successful reservation, scale the matching GPU
      nodegroup, and cancel the losing reservations
  - `status`: summarize candidate nodegroups and any matching ODCR state
  - `cleanup`: scale GPU nodegroups to zero and cancel cluster-tagged ODCRs
- `install-stack.sh`
  - install Gateway API + GAIE CRDs, `agentgateway`, monitoring, the llm-d
    stack, and the customized `HTTPRoute`
  - installs decode at `0` replicas so GPU capacity can be checked first
- `destroy-stack.sh`
  - remove the llm-d stack, monitoring, and `agentgateway`
- `scale-components.sh`
  - scale decode, EPP, and gateway deployments in place
- `scale-decode-with-capacity.sh`
  - `on-demand` and `odcr` modes:
    1. determine how many GPU nodes are required for the target decode replicas
    2. acquire that GPU capacity in AWS
    3. scale decode
- `smoke-test.sh`
  - creates or reuses an in-cluster `curl` client pod
  - runs `/v1/models`, `/v1/completions`, and `/v1/chat/completions`
    against the gateway service without requiring local curl or port-forwarding
- `build-from-scratch.sh`
  - orchestration wrapper that ties the cluster, install, GPU race, and initial
    decode scale-up steps together

## Cold start to 2 decode replicas

```bash
export AWS_PROFILE=552234177002_Eng-FE-Restricted
export AWS_REGION=us-west-2
export LLMD_INFRA_CHART=/path/to/llm-d-infra/charts/llm-d-infra
INITIAL_DECODE_REPLICAS=2 \
guides/inference-scheduling/scripts/aws-agentgateway/build-from-scratch.sh
```

## Scale from 2 decode replicas to 8

```bash
export AWS_PROFILE=552234177002_Eng-FE-Restricted
export AWS_REGION=us-west-2
TARGET_DECODE_REPLICAS=8 \
guides/inference-scheduling/scripts/aws-agentgateway/scale-decode-with-capacity.sh
```

## Notes

- The on-demand race path intentionally prefers real `Ready` nodes over cloud
  API optimism.
- The ODCR path uses immediate-use `open` reservations first, so the winning
  EKS GPU nodegroup can consume the reservation without extra launch-template
  targeting.
- The winner AZ is written to `WINNER_ENV_FILE` if you set it.
- Losing GPU nodegroups are scaled back to zero after a winner is found.
- Losing ODCRs are cancelled after a winner is found.
