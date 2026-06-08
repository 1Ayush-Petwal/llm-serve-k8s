# LLM Serving on Kubernetes — Inference Gateway PoC

An **OpenAI-compatible LLM serving path on Kubernetes**, fronted by the
**[Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/)**
(`InferencePool` / `InferenceObjective` + `HTTPRoute`), with model-aware routing
and metrics — proving the **vLLM ↔ SGLang backend swap is a server-side change
with an identical client**.

Runs **entirely locally for $0**: a `kind` cluster + the `llm-d` inference
**simulator** (no GPU, no model weights, no cloud, no API keys, no database).

## Demo Video: 

**📹 Demo (2 min):** **[Watch the walkthrough on Loom →](https://www.loom.com/share/0531f832b655444184cb7494fd956246)**



`make up → swap → ab → metrics` end-to-end — a 200 through the gateway, the
vLLM→SGLang swap with an unchanged client, the mixed-engine A/B split, and live
Prometheus metrics.



> **Status:** MVP complete — phases 0–6 plus both stretch goals (vLLM→SGLang swap,
> mixed-engine A/B) built and **verified live on `kind`**; captured artifacts are
> inline below. Bring-up is fully scripted (`make up`). See
> `[IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md)` for the design and
> `[llm-serving-k8s-poc.md](./llm-serving-k8s-poc.md)` for the original pitch.

---

## TL;DR

```bash
brew install kind helm            # kubectl already present; start Docker Desktop
make preflight                    # verify host
make up                           # cluster → CRDs+Istio → backend → gateway → 200 OK
make swap                         # vLLM → SGLang, identical client, still 200
```

## Why this exists

The intersection of K8s-native ML infra (CRDs, operators, OpenTelemetry) and the
one gap worth closing: **vLLM/SGLang serving**. It produces *"vLLM/SGLang serving with k8s"* — and lives in the same `kubernetes-sigs` ecosystem as the Gateway API Inference Extension.

---

## What you need (and don't)


|              |                                                                             |
| ------------ | --------------------------------------------------------------------------- |
| **Install**  | Docker (running), `kubectl`, `kind`, `helm`. `istioctl` is auto-downloaded. |
|              |                                                                             |
|              |                                                                             |
| **Cost**     | **$0.** Everything is local on `kind`.                                      |
| **Platform** | Tested target: macOS / Apple Silicon (arm64).                               |


---

## Quickstart (step by step)

```bash
# 0. Host check — flags anything missing (docker daemon, kind, helm…)
make preflight

# 1. Local Kubernetes
make cluster          # kind cluster "llm-serve" + namespace "llm-serving"

# 2. Control plane: Gateway API CRDs + Istio (ext-proc enabled) + Inference CRDs
make control-plane

# 3. The OpenAI-compatible backend (vLLM, simulated — 3 replicas, no GPU)
make backend

# 4. Wire it: InferencePool + Endpoint-Picker (Helm) + Gateway + HTTPRoute + Objective
make gateway

# 5. THE MILESTONE — a request routed through the gateway
make test
```

Captured run (`make test`) — verbatim from a live run (IDs/counts vary per call):

```
==> Gateway service: inference-gateway-istio (namespace llm-serving)
==> Port-forwarding svc/inference-gateway-istio 8080:80

==> POST /v1/completions  model=meta-llama/Llama-3.1-8B-Instruct
HTTP 200
{
  "id": "cmpl-d9d49f08-0f4e-5337-8282-93a00cf3a5f4",
  "created": 1780863893,
  "model": "meta-llama/Llama-3.1-8B-Instruct",
  "usage": { "prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10 },
  "object": "text_completion",
  "kv_transfer_params": null,
  "choices": [
    { "index": 0, "finish_reason": "stop", "text": "I am fine, how " }
  ]
}
✓  MILESTONE: 200 OK routed through the Inference Gateway to a backend pod.
```

Or do it all at once:

```bash
make up        # = cluster → control-plane → backend → gateway → test
```

The raw client call the script makes (note: **plain OpenAI, nothing K8s-specific**):

```bash
curl http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"hello","max_tokens":16}'
```

---

## The headline: vLLM → SGLang with an unchanged client

```bash
make swap     # brings up engine=sglang, scales vLLM to 0, re-runs the SAME curl
```

Because both backends carry the same pool label (`app=llama3-8b`), the
`InferencePool`, Endpoint-Picker, `HTTPRoute`, and `Gateway` **never change** —
and neither does the client. The swap is a pure Deployment change.

```bash
make ab       # variant: leave BOTH engines up → one pool A/Bs across vLLM + SGLang
```

**Captured A/B run** — 30 requests through the **one** gateway/pool, tallied per
pod via each backend's `/metrics` (read through the API-server proxy):

```
burst: 30/30 returned 200
=== per-pod distribution (delta over burst) ===
  [sglang] sglang-llama3-8b-…-hslkr  served=7
  [sglang] sglang-llama3-8b-…-p2p29  served=10
  [sglang] sglang-llama3-8b-…-wfshs  served=2
  [vllm  ] vllm-llama3-8b-…-m5dzm    served=3
  [vllm  ] vllm-llama3-8b-…-snzrw    served=6
  [vllm  ] vllm-llama3-8b-…-tm2mh    served=2
>>> burst served by  ENGINE=vLLM: 11   |   ENGINE=SGLang: 19   (of 30)
```

All 30 returned `200` and traffic fanned across **both engines through a single
InferencePool / EPP / HTTPRoute** with an unchanged client. The per-pod deltas sum
to exactly 30 — every request accounted for — so this is model-aware routing over a
mixed-engine pool, demonstrated rather than asserted.

> **Honesty note:** upstream ships no SGLang *simulator* (only a GPU deployment),
> so the swap target reuses the same inference-sim image relabeled
> `engine=sglang`. This proves the **Kubernetes-level portability claim** — server
> swap, identical client — **not** SGLang's runtime behavior. The runtime
> comparison is the Phase-2 GPU benchmark below.

### vLLM vs SGLang — the tradeoff

Both expose an **OpenAI-compatible HTTP API**, so the client stays identical and
the choice is a server-side decision:

- **SGLang** — RadixAttention (prefix-cache reuse) tends to win on
**shared-prefix / multi-turn / agentic** workloads.
- **vLLM** — broader **ecosystem maturity and model coverage**; the default
workhorse.

The *real* throughput/latency comparison needs a GPU and is **Phase 2**.

---

## Observability

```bash
make metrics
```

Scrapes Prometheus `/metrics` from the simulated backend (OpenAI/vLLM-style
series: request counts, latency histograms, token counters, KV-cache) —
token-free. Routing decisions live in the Endpoint-Picker; the script prints how
to inspect EPP logs/metrics too.

Captured excerpt (`make metrics`) — verbatim:

```
----- backend metrics (filtered) ---------------------------------------
vllm:cache_config_info{block_size="16",num_gpu_blocks="1024"} 1
vllm:e2e_request_latency_seconds_bucket{model_name="meta-llama/Llama-3.1-8B-Instruct",le="0.3"} 8
vllm:e2e_request_latency_seconds_bucket{model_name="meta-llama/Llama-3.1-8B-Instruct",le="1"} 8
…  (full le="…" histogram ladder up to +Inf)  …
vllm:e2e_request_latency_seconds_sum{model_name="meta-llama/Llama-3.1-8B-Instruct"} 0.003026583
vllm:e2e_request_latency_seconds_count{model_name="meta-llama/Llama-3.1-8B-Instruct"} 8
vllm:generation_tokens_total{model_name="meta-llama/Llama-3.1-8B-Instruct"} 25
vllm:inter_token_latency_seconds_bucket{model_name="meta-llama/Llama-3.1-8B-Instruct",le="0.01"} 17
------------------------------------------------------------------------
```

These `vllm:*` series are exactly what the Endpoint-Picker scrapes from each pod to
make load-aware routing decisions — and the same metrics a Phase-2 GPU benchmark
would chart (TTFT, inter-token latency, throughput).

---

## Phase 2 — the one paid follow-up (deferred)

The simulator emulates the **protocol**, not GPU performance. The single
experiment that turns *"I wired it up"* into *"I measured it"*:

> **vLLM vs SGLang on Llama-3.1-8B**, ~2 hrs on one spot GPU. Measure tokens/sec,
> TTFT, p50/p95/p99 latency, and throughput on shared-prefix vs unique-prompt
> workloads (where RadixAttention should show).

Mechanically: swap `manifests/*-sim-deployment.yaml` for the upstream
`vllm/gpu-deployment.yaml` / `sglang/gpu-deployment.yaml`. **The gateway wiring is
unchanged** — which is the whole point.

---

## Repository layout

```
.
├── README.md                     # you are here
├── IMPLEMENTATION_PLAN.md        # design, decisions, milestones, risks
├── llm-serving-k8s-poc.md        # original pitch
├── Makefile                      # `make help` for the menu
├── .env.example                  # documents optional knobs (NO secrets)
├── manifests/
│   ├── kind-cluster.yaml         # local cluster
│   ├── gateway-istio.yaml        # Gateway (gatewayClassName: istio)
│   ├── vllm-sim-deployment.yaml  # backend A — engine=vllm
│   ├── sglang-sim-deployment.yaml# backend B — engine=sglang (swap target)
│   ├── httproute.yaml            # Gateway → InferencePool
│   └── inference-objective.yaml  # serving priority
└── scripts/
    ├── lib.sh                    # single source of pinned versions + naming
    ├── 00-preflight.sh
    ├── 01-cluster-up.sh
    ├── 02-install-gateway.sh     # Gateway API CRDs + Istio + Inference CRDs
    ├── 03-deploy-backend.sh
    ├── 04-wire-gateway.sh        # InferencePool (Helm) + Gateway + Route + Objective
    ├── 05-smoke-test.sh
    ├── 06-observability.sh
    ├── swap-to-sglang.sh
    └── 99-teardown.sh
```

## Teardown

```bash
make clean    # remove workloads, keep the cluster
make down     # delete the whole kind cluster
```

## Pinned versions

`gateway-api-inference-extension v1.5.0` · `gateway-api CRDs v1.5.1` ·
`Istio 1.28.0+` · `ghcr.io/llm-d/llm-d-inference-sim:v0.8.2`. All in
`scripts/lib.sh`, each overridable by env var.

## References

- Inference Extension — Getting Started: [https://gateway-api-inference-extension.sigs.k8s.io/guides/](https://gateway-api-inference-extension.sigs.k8s.io/guides/)
- Project repo: [https://github.com/kubernetes-sigs/gateway-api-inference-extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
- llm-d inference simulator: [https://github.com/llm-d/llm-d-inference-sim](https://github.com/llm-d/llm-d-inference-sim)
- KServe + llm-d + vLLM production pattern: [https://llm-d.ai/blog/production-grade-llm-inference-at-scale-kserve-llm-d-vllm](https://llm-d.ai/blog/production-grade-llm-inference-at-scale-kserve-llm-d-vllm)

---

