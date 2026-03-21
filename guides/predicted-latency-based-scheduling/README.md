# Experimental Feature: Predicted Latency based Load Balancing

## Overview

This experimental feature introduces **predicted latency based load balancing**, where scheduling decisions are guided by real-time predictions of request latency rather than only utilization metrics like queue depth or KV-cache utilization.

- **Problem:** Utilization-based load balancing misses some distinct characteristics of LLM workloads, leading to requests missing SLO targets or leads to overly conservative routing that wastes capacity.
- **Approach:** The Endpoint Picker (EPP) integrates with **in-pod latency predictor sidecars** that continuously learn from live traffic. These sidecars estimate **p90 TTFT** and **p90 TPOT** for each candidate pod given current load, prefix cache state, and request features.
- **Outcome:** The **SLO scorer** compares predictions against per-request SLOs and directs traffic to pods with some headroom. If none exist, requests are shed (priority < 0) or sent to a weighted pool favoring lower latency pods.

### Tradeoffs & Gaps

- **Homogeneous InferencePool**
  Current predictors assume that all model server pods are identical (same GPU type, model weights, and serving configuration). Heterogeneous pools are not yet modeled.

- **Scaling limits**
  Each prediction sidecar can sustain ~300 QPS on a c4-standard-192 Google cloud machine (**≈ 192 vCPUs, 720 GB RAM, Up to 100 Gbps network, Up to 200 Gbps aggregate throughput**). Because the EPP makes one prediction call per candidate pod, total prediction load grows with both **cluster QPS** and **pod count**. If traffic or pod count increases, prediction servers must be scaled horizontally.

- **Training mode**
  Only streaming workloads (set **"stream": "true"** in the request body as per openAI protocol) are supported.

- **Percentiles**
  The predictor currently estimates only **p90** TTFT and TPOT. Other percentiles (p95, p99) or a mix of percentiles are not yet available.

- **Prefill/Decode disaggregation**
  Current routing does **not support prefill/decode disaggregation** (where one pod performs prefill and another performs decode). Prediction and SLO scoring assume a pod executes the entire request lifecycle. Support for disaggregated serving is a **work in progress**.

- **Unvalidated against advanced inference features**
  Predictions have not yet been tested with advanced serving strategies such as LoRA adapters, speculative decoding, or beam search. Each of these may shift latency characteristics (e.g., speculative decoding may reduce TTFT but increase TPOT variance), and models may need to be extended to remain accurate in these contexts.

### What is Tested

This feature has been validated against the scenarios described in the [original design doc](https://docs.google.com/document/d/1q56wr3N5XGx0B21MzHu5oBsCiGi9VrbZAvyhP2VFG_c/edit?tab=t.0#heading=h.ob7j9esmcyd3) — including **short-prompt/long-completion**, **long-prompt/short-completion**, and **mixed workloads** — to compare a direct backend baseline versus prediction-based SLO routing through the gateway. The committed comparison artifacts and the end-to-end reproduction flow are tracked in [../../docs/infra-providers/gke/VALIDATION-TRACKER.md](../../docs/infra-providers/gke/VALIDATION-TRACKER.md) and [../../docs/infra-providers/gke/HANDOFF.md](../../docs/infra-providers/gke/HANDOFF.md).

This guide explains how to deploy EPP with latency predictor sidecars, configure profiles and scorers, and enable **SLO-aware routing** via headers.

---

## Validated llm-d Workflow

The current validated llm-d path does **not** require building custom GAIE images from the
experimental branch. GAIE `v1.4.0` already ships latency-predictor support in the released
`inferencepool` chart.

The workflow validated in this repository layers prediction-based scheduling on top of the
backend deployed by the precise guide:

1. Deploy the precise backend:
   - [../precise-prefix-cache-aware/README.md](../precise-prefix-cache-aware/README.md)
2. Apply the direct baseline Service if you want a backend-only control:
   - [../precise-prefix-cache-aware/direct-service.yaml](../precise-prefix-cache-aware/direct-service.yaml)
3. Install a second `InferencePool` with latency prediction enabled:
   - [./values.yaml](./values.yaml)
4. Apply a header-matched `HTTPRoute` that sends only tagged requests to the predicted-latency pool:
   - [./httproute.yaml](./httproute.yaml)

This keeps the existing precise route intact and makes A/B testing possible on one live cluster:

- direct backend baseline: `ms-kv-events-direct`
- existing gateway path: `infra-kv-events-inference-gateway`
- predicted-latency path: `infra-kv-events-inference-gateway` with `x-routing-scenario: predicted-latency`

## Prerequisites

- Deploy the precise guide stack and make sure it is healthy.
- Install the Gateway API, GAIE CRDs, `agentgateway`, and monitoring as described in the
  llm-d prerequisite guides.
- Ensure the `llmd` namespace contains the `llm-d-hf-token` secret.

## Install The Predicted-Latency Pool

```bash
helm upgrade --install gaie-predicted-latency \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.4.0 \
  -n llmd \
  -f guides/predicted-latency-based-scheduling/values.yaml

kubectl apply -n llmd -f guides/predicted-latency-based-scheduling/httproute.yaml
kubectl rollout status deployment/gaie-predicted-latency-epp -n llmd --timeout=300s
```

## Smoke Test

Check the predictor sidecars through the EPP service:

```bash
kubectl run predlat-check --rm -i --restart=Never -n llmd \
  --image=curlimages/curl:8.12.1 --command -- sh -lc '
curl -sS http://gaie-predicted-latency-epp:8000/readyz
curl -sS http://gaie-predicted-latency-epp:8001/readyz
'
```

Check the direct backend baseline:

```bash
kubectl run predlat-direct-smoke --rm -i --restart=Never -n llmd \
  --image=curlimages/curl:8.12.1 --command -- sh -lc '
cat <<EOF >/tmp/request.json
{"model":"Qwen/Qwen3-32B","prompt":"Say hello in one short sentence.","max_tokens":32}
EOF
curl -sS --fail-with-body \
  -H "Content-Type: application/json" \
  --data @/tmp/request.json \
  http://ms-kv-events-direct:80/v1/completions
'
```

Check the predicted-latency route through the gateway:

```bash
GW_IP=$(kubectl get svc infra-kv-events-inference-gateway -n llmd -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -N --fail-with-body "http://${GW_IP}/v1/completions" \
  -H 'Content-Type: application/json' \
  -H 'x-routing-scenario: predicted-latency' \
  -H 'x-slo-ttft-ms: 5000' \
  -H 'x-slo-tpot-ms: 100' \
  -d '{
    "model": "Qwen/Qwen3-32B",
    "prompt": "what is the difference between Franz and Apache Kafka?",
    "max_tokens": 200,
    "temperature": 0,
    "stream": true
  }'
```

The final SSE frame should include both actuals and predictions, for example:

   ```text
   < HTTP/1.1 200 OK
   < content-type: text/event-stream; charset=utf-8
   ...
   data: {"choices":[{"index":0,"text":" Apache"}], "object":"text_completion", ...}
   data: {"choices":[{"index":0,"text":" Kafka"}],  "object":"text_completion", ...}
   ... (many streamed tokens) ...
   data: {
     "object":"text_completion",
     "usage": {
       "prompt_tokens": 12,
       "completion_tokens": 200,
       "total_tokens": 212,
       "ttft_ms": 59,
       "tpot_observations_ms": [9, 6],
       "avg_tpot_ms": 7.5,
       "predicted_ttft_ms": 273.23,
       "predicted_tpot_observations_ms": [176.22, 18.17],
       "avg_predicted_tpot_ms": 97.19
     }
   }
   data: [DONE]
   ```

   - The final SSE frame includes both **predictions and actuals** so you can validate accuracy (e.g., `predicted_ttft_ms` vs `ttft_ms`).
   - TPOTs are sampled every 200th token and surfaced in the arrays like `tpot_observations_ms`.

## Benchmarking

Use [../benchmark/predicted_latency_template.yaml](../benchmark/predicted_latency_template.yaml).
It covers the three workload classes we validated:

- short prompt / long completion
- long prompt / short completion
- mixed workload

Run the backend-only baseline first:

```bash
export NAMESPACE=llmd
export BENCHMARK_PVC=<your benchmark pvc>
export LLMD_ROOT_DIR=../..
export BENCH_TEMPLATE_DIR="${LLMD_ROOT_DIR}/guides/benchmark"
export GATEWAY_SVC=ms-kv-events-direct
export BENCHMARK_TEMPLATE="${BENCH_TEMPLATE_DIR}/predicted_latency_template.yaml"
./run_only.sh -c "${BENCHMARK_TEMPLATE}"
```

Then run the predicted-latency scheduler path with the same template plus request headers:

```bash
export GATEWAY_SVC=infra-kv-events-inference-gateway
cp "${BENCH_TEMPLATE_DIR}/predicted_latency_template.yaml" /tmp/predicted-latency-benchmark.yaml
yq -i '.workload[] .api.headers = {"x-routing-scenario":"predicted-latency","x-slo-ttft-ms":"5000","x-slo-tpot-ms":"100"}' \
  /tmp/predicted-latency-benchmark.yaml
./run_only.sh -c /tmp/predicted-latency-benchmark.yaml
```

For a tighter routing-only comparison, you can also run the same benchmark against the gateway
without the predicted-latency headers. That isolates default gateway routing versus
predicted-latency routing on the same backend.

## Validate Predictions In Logs

Tail EPP logs at verbosity `-v=4`. For each request you should see:

   - **Profile selection**

     ```text
     msg:"Running profile handler, Pick profiles"
     plugin:"slo-aware-profile-handler/slo-aware-profile-handler"
     ```

   - **Candidate pods**

     ```text
     msg:"Before running scorer plugins"
     pods:[{... "pod_name":"...-5k7qr" ...}, {... "pod_name":"...-9lp5g" ...}]
     ```

   - **SLO scorer pod scores**

     ```text
     msg:"Pod score"
     scorer_type:"slo-scorer"
     pod_name:"vllm-llama3-8b-instruct-7b584dd595-9b4wt"
     score:0.82
     ```

   - **Final pick**

     ```text
     msg:"Picked endpoint"
     scorer_type:"slo-scorer"
     selected_pod:"vllm-llama3-8b-instruct-7b584dd595-9b4wt"
     ```

   These logs confirm:
   - The request entered the SLO-aware path.
   - All candidate pods were evaluated.
   - Scores reflect predicted headroom vs SLOs.
   - The final pod was chosen based on SLO scorer output.

You should also see the latency-predictor client and model-training path active, for example:

```text
plugin":"predicted-latency-scorer/predicted-latency-scorer"
msg":"bulk prediction succeeded"
msg":"Recording TTFT training data"
msg":"First inter-token latency observed"
```

## Historical Note

Older versions of this guide described building custom images from the
`slo-prediction-experimental` branch of GAIE. That was necessary before the
released `inferencepool` chart grew built-in latency-predictor support. The current
validated llm-d path uses the released chart instead.

---

## Configuration

This section details the container setup, ConfigMaps, and profile configuration needed to enable prediction-based scheduling.

### Sidecars & EPP containers in the Deployment

#### EPP container

- **Image**: `epp`
- **Args**
  - `--config-file=/config/default-plugins.yaml`
  - `--enable-latency-predictor`
- **Env**
  - `PREDICTION_SERVER_URL`: CSV of in-pod predictor endpoints
  - `TRAINING_SERVER_URL`: `http://localhost:8000`
  - `LATENCY_MAX_SAMPLE_SIZE`
  - `NEG_HEADROOM_TTFT_WEIGHT`, `NEG_HEADROOM_TPOT_WEIGHT`
  - `HEADROOM_TTFT_WEIGHT`, `HEADROOM_TPOT_WEIGHT`
  - `HEADROOM_SELECTION_STRATEGY`
  - `SLO_BUFFER_FACTOR`

**Training sidecar (`training-server`)**

- **Port**: 8000
- **EnvFrom**: `latency-predictor-config`
- **Volume**: `/models`

**Prediction sidecars (`prediction-server-1/2/3`)**

- **Ports**: 8001, 8002, 8003
- **EnvFrom**: `prediction-server-config`
- **Volumes**: `/server_models`

---

### ConfigMaps

**1. `latency-predictor-config` (training)**

```yaml
data:
  LATENCY_RETRAINING_INTERVAL_SEC: "1"
  LATENCY_MIN_SAMPLES_FOR_RETRAIN: "100"
  LATENCY_TTFT_MODEL_PATH: "/models/ttft.joblib"
  LATENCY_TPOT_MODEL_PATH: "/models/tpot.joblib"
  LATENCY_TTFT_SCALER_PATH: "/models/ttft_scaler.joblib"
  LATENCY_TPOT_SCALER_PATH: "/models/tpot_scaler.joblib"
  LATENCY_MODEL_TYPE: "xgboost"
  LATENCY_MAX_TRAINING_DATA_SIZE_PER_BUCKET: "5000"
```

**2. `prediction-server-config` (predictors)**

```yaml
data:
  LATENCY_MODEL_TYPE: "xgboost"
  PREDICT_HOST: "0.0.0.0"
  LOCAL_TTFT_MODEL_PATH: "/server_models/ttft.joblib"
  LOCAL_TPOT_MODEL_PATH: "/server_models/tpot.joblib"
  LOCAL_TTFT_SCALER_PATH: "/server_models/ttft_scaler.joblib"
  LOCAL_TPOT_SCALER_PATH: "/server_models/tpot_scaler.joblib"
```

---

### Profiles & Plugins

`plugins-config` ConfigMap (`default-plugins.yaml`):

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha1
kind: EndpointPickerConfig
plugins:
  - type: queue-scorer
  - type: kv-cache-utilization-scorer
  - type: prefix-cache-scorer
  - type: slo-request-tracker
  - type: slo-scorer
  - type: slo-aware-profile-handler
  - type: max-score-picker

schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: slo-request-tracker
      - pluginRef: prefix-cache-scorer
      - pluginRef: queue-scorer
      - pluginRef: kv-cache-utilization-scorer
      - pluginRef: max-score-picker

  - name: slo
    plugins:
      - pluginRef: prefix-cache-scorer
        weight: 0
      - pluginRef: slo-request-tracker
      - pluginRef: slo-scorer
      - pluginRef: max-score-picker
```

#### What they do

- `slo-request-tracker` — captures per-request SLOs and tracks them.
- `slo-scorer` — uses predicted TTFT/TPOT to compare against SLOs and classify into positive/negative buckets.
- `slo-aware-profile-handler` — switches requests into the `slo` profile when SLO headers are present.
- `queue-scorer`, `kv-cache-utilization-scorer`, `prefix-cache-scorer` — baseline scoring plugins.

---

### Headroom strategies

Tune positive vs negative headroom scoring with env vars:

- `HEADROOM_SELECTION_STRATEGY` — `least` (compact) or `most` (spread)
- `HEADROOM_TTFT_WEIGHT` / `HEADROOM_TPOT_WEIGHT` — blend weights for positive headroom
- `NEG_HEADROOM_TTFT_WEIGHT` / `NEG_HEADROOM_TPOT_WEIGHT` — blend weights for deficits
- `SLO_BUFFER_FACTOR` — safety multiplier on TPOT SLOs

---

### Enable prediction-based scheduling

Turn on SLO-aware routing per request with the header:

```text
x-prediction-based-scheduling: true
```

- If **SLO headers are present**: predictions are compared against thresholds.
- If **no SLOs** are provided: treated as SLO=0 → lowest latency pod is chosen.
- If **priority < 0** and **no pod can meet SLOs**: request is **shed** instead of placed in the negative bucket.

#### Current limitations

- Percentile: only **p90** supported.
- Training: only **streaming mode** supported.
- TPOT sampling: for obsevability, every 200th token is logged and compared with predictions.

---

## Cleanup

To remove the resources you created in this walkthrough, follow the same cleanup instructions from the [Inference Gateway Extension guide](https://gateway-api-inference-extension.sigs.k8s.io/guides/#cleanup).

That section covers how to delete the InferencePool, ConfigMaps, and supporting resources you applied here. The steps are identical — only the EPP image and sidecar configuration differ.
