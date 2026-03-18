# Local E2E Validation with Kind and Agentgateway

This document captures the exact manual steps used to recreate the local end-to-end validation environment for the `simulated-accelerators` guide with:

- Gateway API CRDs `v1.5.0`
- Gateway API Inference Extension (GAIE) CRDs and chart `v1.4.0-rc.3`
- `agentgateway` `v1.0.0-alpha.4`
- a local `llm-d-infra` chart checkout
- downstream scheduler images:
  - `docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.1`
  - `docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.1`

## Prerequisites

- A local checkout of `llm-d`:

  ```bash
  /Users/solo-system-dhansen/go/src/github.com/llm-d/llm-d
  ```

- A local checkout of `llm-d-infra`:

  ```bash
  /Users/solo-system-dhansen/go/src/github.com/llm-d-incubation/llm-d-infra
  ```

- Installed client tools:
  - `kind`
  - `kubectl`
  - `helm`
  - `helmfile`
  - `docker`

## 1. Export the test configuration

```bash
cd /Users/solo-system-dhansen/go/src/github.com/llm-d/llm-d

export GATEWAY_API_CRD_REVISION="v1.5.0"
export GATEWAY_API_INFERENCE_EXTENSION_CRD_REVISION="v1.4.0-rc.3"

export LLMD_INFRA_CHART="/Users/solo-system-dhansen/go/src/github.com/llm-d-incubation/llm-d-infra/charts/llm-d-infra"

export LLMD_INFERENCE_SCHEDULER_IMAGE_HUB="docker.io/danehans"
export LLMD_INFERENCE_SCHEDULER_IMAGE_NAME="llm-d-inference-scheduler"
export LLMD_INFERENCE_SCHEDULER_IMAGE_TAG="v0.7.0-rc.1"

export LLMD_ROUTING_SIDECAR_IMAGE="docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.1"
```

## 2. Create a fresh kind cluster

```bash
kind create cluster --name llmd-gaie-140rc3 --image kindest/node:v1.34.0
kubectl config use-context kind-llmd-gaie-140rc3
kubectl wait --for=condition=Ready node/llmd-gaie-140rc3-control-plane --timeout=180s
```

## 3. Install Gateway API and GAIE CRDs

```bash
guides/prereq/gateway-provider/install-gateway-provider-dependencies.sh
```

## 4. Install `agentgateway`

```bash
helmfile -f guides/prereq/gateway-provider/agentgateway.helmfile.yaml apply
kubectl wait --for=condition=Available deployment/agentgateway -n agentgateway-system --timeout=180s
```

## 5. Install monitoring

```bash
docs/monitoring/scripts/install-prometheus-grafana.sh
```

## 6. Create the application namespace

```bash
kubectl create namespace llm-d-sim
```

## 7. Deploy the simulated-accelerators stack

```bash
helmfile -f guides/simulated-accelerators/helmfile.yaml.gotmpl \
  -e agentgateway \
  -n llm-d-sim \
  apply
```

## 8. Install the HTTPRoute

```bash
kubectl apply -f guides/simulated-accelerators/httproute.yaml -n llm-d-sim
```

## 9. Wait for readiness

```bash
kubectl wait pod --for=condition=Ready --all -n llm-d-sim --timeout=300s
kubectl wait gateway/infra-sim-inference-gateway --for=condition=Programmed=True -n llm-d-sim --timeout=300s
kubectl wait httproute/llm-d-sim --for=condition=Accepted=True -n llm-d-sim --timeout=300s
kubectl wait httproute/llm-d-sim --for=condition=ResolvedRefs=True -n llm-d-sim --timeout=300s
```

## 10. Verify the expected images

```bash
kubectl get deploy gaie-sim-epp -n llm-d-sim -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get deploy ms-sim-llm-d-modelservice-decode -n llm-d-sim -o jsonpath='{.spec.template.spec.initContainers[0].image}{"\n"}'
```

Expected output:

```text
docker.io/danehans/llm-d-inference-scheduler:v0.7.0-rc.1
docker.io/danehans/llm-d-routing-sidecar:v0.7.0-rc.1
```

## 11. Verify the gateway service type

```bash
kubectl get agentgatewayparameters.agentgateway.dev infra-sim-inference-gateway \
  -n llm-d-sim \
  -o jsonpath='{.spec.service.spec.type}{"\n"}'
```

Expected output:

```text
LoadBalancer
```

## 12. Run smoke tests

In one terminal:

```bash
kubectl port-forward -n llm-d-sim service/infra-sim-inference-gateway 18000:80
```

In another terminal:

```bash
curl -sS --fail-with-body http://127.0.0.1:18000/v1/models
```

```bash
curl -sS --fail-with-body \
  -H 'Content-Type: application/json' \
  -d '{"model":"random","prompt":"Say hello in one short sentence.","max_tokens":32}' \
  http://127.0.0.1:18000/v1/completions
```

```bash
curl -sS --fail-with-body \
  -H 'Content-Type: application/json' \
  -d '{"model":"random","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":32}' \
  http://127.0.0.1:18000/v1/chat/completions
```

## 13. Useful inspection commands

```bash
kubectl get pods -n llm-d-sim
kubectl get gateway,httproute -n llm-d-sim
kubectl get svc -n llm-d-sim
kubectl get agentgatewayparameters.agentgateway.dev infra-sim-inference-gateway -n llm-d-sim -o yaml
```

## Notes

- In kind, the inference gateway service is `LoadBalancer` with `EXTERNAL-IP` left as `<pending>`. Use `kubectl port-forward` for local smoke tests.
- This flow intentionally uses env-based image overrides so the repo defaults do not need to be changed for a one-off downstream scheduler validation.
- The local `llm-d-infra` chart override is required when validating chart changes that have not yet been released.
