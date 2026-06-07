# LLM Serving on Kubernetes — Inference Gateway PoC

**Repo:** `1Ayush-Petwal/llm-serve-k8s` (suggested)
**Goal of this PoC:** Stand up an OpenAI-compatible LLM serving path on Kubernetes, fronted by the **Gateway API Inference Extension (IGW / llm-d)**, with model-aware routing and metrics — and prove the **vLLM ↔ SGLang backend swap** is a server change with an identical client.
**Constraint:** **$0.** No GPU rental, no cloud. Everything runs locally on a `kind` cluster using the **llm-d inference simulator** (no model weights, no GPU).

> Why this project: it's the exact intersection of what I already have (K8s-native ML infra, CRDs, OpenTelemetry observability from Kubeflow) and the one gap I'm closing (vLLM/SGLang serving). It produces the literal phrase recruiters screen for — "vLLM/SGLang serving + k8s" — and lives in the same `kubernetes-sigs` ecosystem as my existing Kubeflow PRs.

---

## What this PoC proves tonight

- Deploying an OpenAI-compatible model server as a K8s workload.
- Putting the **Inference Gateway** (`InferencePool` + `InferenceObjective` CRDs + `HTTPRoute`) in front of it — the same CRD/operator muscle as my Kubeflow SparkCluster work, pointed at LLM serving.
- Backend portability: vLLM → SGLang with the **client unchanged** (both expose OpenAI-compatible HTTP endpoints).
- Basic observability: scraping the gateway/Endpoint-Picker and sim metrics.

## What it deliberately does NOT prove (Phase 2, when there's budget)

- Real throughput/latency on real hardware. The sim emulates the protocol, not GPU performance. A single real benchmark (vLLM vs SGLang on Llama 3.1 8B, ~2 hrs on a spot GPU) is the one paid follow-up that turns "I wired it up" into "I measured it."

---

## Prerequisites (all free)

- Docker
- `kind` (Kubernetes-in-Docker)
- `kubectl`
- `helm`

```bash
# sanity check
docker --version && kind --version && kubectl version --client && helm version
```

---

## Build steps (target: one evening)

> Pin the release tag from the **official Getting Started guide** before running — the manifest URLs use a `${IGW_LATEST_RELEASE}` tag that must be set to the current release. Guide: https://gateway-api-inference-extension.sigs.k8s.io/guides/

**1. Local cluster (~5 min)**
```bash
kind create cluster --name llm-serve
kubectl create namespace llm-serving
```

**2. Install Gateway API + the Inference Extension CRDs (~15 min)**
- Install Gateway API CRDs.
- Install an ext-proc–capable gateway (Envoy Gateway or kgateway).
- Install the Inference Extension CRDs (`InferencePool`, `InferenceObjective`).
- Follow the exact `kubectl apply` / `helm` lines from the Getting Started guide for the pinned tag.

**3. Deploy the vLLM SIMULATOR backend — no GPU (~15 min)**
```bash
export IGW_LATEST_RELEASE=<set-from-guide>
export INFERENCE_POOL_NAME=vllm-sim
export MODEL_NAME=meta-llama/Llama-3.1-8B-Instruct   # name only; sim does not load weights

kubectl apply -f \
  https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/refs/tags/${IGW_LATEST_RELEASE}/config/manifests/vllm/sim-deployment.yaml
```
(Sim image: `ghcr.io/llm-d/llm-d-inference-sim`.)

**4. Wire the gateway → pool (~15 min)**
- Apply `InferencePool` targeting the sim deployment.
- Apply `InferenceObjective` (e.g. a "critical" serving objective).
- Apply `HTTPRoute` routing the model name to the pool.

**5. Send a request through the gateway (~10 min)**
```bash
# port-forward the gateway, then:
curl http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"hello","max_tokens":16}'
```
✅ **Milestone:** a 200 with an OpenAI-shaped response routed through the inference gateway.

**6. Observability (~15 min)**
- Expose the Endpoint-Picker / sim Prometheus metrics.
- Capture request count, queue depth, and per-request routing decisions. A screenshot or `curl /metrics` dump is enough for the README.

---

## Stretch goals (only if time remains)

- **SGLang swap:** point the pool at an SGLang backend (sim or CPU) and re-run the *same* curl — demonstrate client code is unchanged. This is the headline "I understand the vLLM/SGLang tradeoff" artifact.
- **A/B / model rewrite:** route two model names to the same pool to show model-aware routing.
- **OpenTelemetry trace** on the request path (ties directly to my Kubeflow OTel work).

---

## Success criteria (what goes in the README)

1. `kind` cluster + Inference Gateway up, reproducible from the README.
2. One screenshot/log of a request routed through the gateway to the backend.
3. A short "vLLM vs SGLang" section: both are OpenAI-compatible, so the client stays identical; SGLang's RadixAttention tends to win on shared-prefix/multi-turn workloads, vLLM wins on ecosystem maturity and model breadth. Note the real benchmark is Phase 2.
4. A "Phase 2 / GPU benchmark" section stating exactly what would be measured and why it's deferred.

## How to describe it in the DM

> "Deployed an OpenAI-compatible LLM serving path on Kubernetes behind the Gateway API Inference Extension (llm-d), with model-aware routing via InferencePool/InferenceObjective and request metrics — backend-portable across vLLM and SGLang. Repo + writeup here. GPU throughput benchmark is the next step."

---

## References

- Inference Extension — Getting Started: https://gateway-api-inference-extension.sigs.k8s.io/guides/
- Project repo: https://github.com/kubernetes-sigs/gateway-api-inference-extension
- KServe + llm-d + vLLM production pattern: https://llm-d.ai/blog/production-grade-llm-inference-at-scale-kserve-llm-d-vllm
