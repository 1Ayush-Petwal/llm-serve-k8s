# Implementation Plan — LLM Serving on Kubernetes (Inference Gateway PoC)

> Companion to `[llm-serving-k8s-poc.md](./llm-serving-k8s-poc.md)`. That file is
> the pitch; this file is the buildable plan + the exact moving parts. Runnable
> instructions live in `[README.md](./README.md)`.

## 0. The goal in one sentence

Stand up an **OpenAI-compatible LLM serving path on Kubernetes**, fronted by the
**Gateway API Inference Extension** (`InferencePool` / `InferenceObjective` +
`HTTPRoute`), and prove the **vLLM ↔ SGLang backend swap is a server-side change
with an identical client** — all for **$0**, locally, on `kind`, using the
`llm-d` inference simulator (no GPU, no model weights).

---

## 1. Prerequisites

This is the part most people get wrong by reflex. Stated plainly:

### Tooling to install


| Tool               | Why                                         | Install                                            |
| ------------------ | ------------------------------------------- | -------------------------------------------------- |
| Docker             | `kind` runs Kubernetes in Docker            | Docker Desktop (start the daemon)                  |
| kubectl            | talk to the cluster                         | `brew install kubectl`                             |
| kind               | local Kubernetes                            | `brew install kind`                                |
| helm               | the **InferencePool ships as a Helm chart** | `brew install helm`                                |
| istioctl           | the gateway provider                        | auto-downloaded by `scripts/02-install-gateway.sh` |
| jq, envsubst, curl | scripting glue                              | present on macOS / `brew install gettext`          |


---

## 2. Architecture

```
        curl /v1/completions   ← OpenAI-compatible client, IDENTICAL across engines
                  │
                  ▼
        ┌─────────────────────────┐
        │  Gateway (Istio)         │  gatewayClassName: istio
        │  name: inference-gateway │  istiod: ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
        └───────────┬─────────────┘
                    │  HTTPRoute "llm-route"  (backendRef kind: InferencePool)
                    ▼
        ┌─────────────────────────┐
        │  Endpoint-Picker (EPP)   │  ext-proc · model-aware routing
        │  + InferencePool         │  + InferenceObjective (priority=1)
        └───────────┬─────────────┘
                    │  selects a pod by label  app=llama3-8b
        ┌───────────┴───────────────┐
        ▼                           ▼
┌──────────────────┐       ┌──────────────────┐
│ vllm-llama3-8b   │  swap │ sglang-llama3-8b │   ← same label, same pool,
│ engine=vllm      │ <───> │ engine=sglang    │     same route, same client
│ (inference-sim)  │       │ (inference-sim)  │
└──────────────────┘       └──────────────────┘
```

**The key design decision:** both backends carry the **same selector label**
(`app=llama3-8b`). That is what makes the swap a pure Deployment change —
the `InferencePool`, EPP, `HTTPRoute`, and `Gateway` never change, and neither
does the client. It also makes the A/B demo free: leave both up and the pool
load-balances across engines.

---

## 3. Pinned versions (verified live against GitHub)


| Component                       | Version                                    | Source of truth                          |
| ------------------------------- | ------------------------------------------ | ---------------------------------------- |
| gateway-api-inference-extension | `v1.5.0`                                   | GitHub Releases (latest stable)          |
| sigs.k8s.io/gateway-api CRDs    | `v1.5.1`                                   | GitHub Releases (latest)                 |
| Istio                           | `1.28.0+`                                  | required for `InferencePool` v1 ext-proc |
| inference simulator image       | `ghcr.io/llm-d/llm-d-inference-sim:v0.8.2` | upstream sim-deployment                  |


All pins live in **one place**: `scripts/lib.sh` (each overridable via env).

---

## 4. Build phases → scripts → milestones


| Phase            | Script / `make` target | Proves                      | Milestone                                                        |
| ---------------- | ---------------------- | --------------------------- | ---------------------------------------------------------------- |
| 0. Preflight     | `make preflight`       | host is ready               | all ✓, daemon up                                                 |
| 1. Cluster       | `make cluster`         | local K8s                   | `kind` node Ready, ns `llm-serving`                              |
| 2. Control plane | `make control-plane`   | CRDs + provider             | Gateway API + Istio + Inference CRDs Established                 |
| 3. Backend       | `make backend`         | OpenAI server as a workload | 3 sim pods Ready (`engine=vllm`)                                 |
| 4. Wire gateway  | `make gateway`         | the CRD/operator muscle     | Gateway **Programmed**, EPP Ready, HTTPRoute + Objective applied |
| 5. Smoke test    | `make test`            | end-to-end routing          | **200** OpenAI-shaped response through the gateway               |
| 6. Observability | `make metrics`         | basic telemetry             | `/metrics` dump: request count / queue / running                 |
| S1. SGLang swap  | `make swap`            | **backend portability**     | identical curl → 200, served by `engine=sglang`                  |
| S2. A/B routing  | `make ab`              | model-aware routing         | one pool, both engines serving                                   |


`make up` runs phases 1–5 in order.

---

## 5. Resource inventory (what gets created)

- **Cluster-scoped:** Gateway API CRDs, Inference Extension CRDs (`InferencePool`,
`InferenceObjective`), Istio control plane (`istio-system`).
- **Namespace `llm-serving`:**
  - `Deployment/vllm-llama3-8b` (3× sim, `engine=vllm`)
  - `Deployment/sglang-llama3-8b` (stretch; `engine=sglang`)
  - `InferencePool/llama3-8b-pool` + `Deployment/llama3-8b-pool-epp` (Helm)
  - `Gateway/inference-gateway` (+ Istio-created `Service/inference-gateway-istio`)
  - `HTTPRoute/llm-route`
  - `InferenceObjective/default-objective`

---

## 6. Success criteria (these are the README deliverables)

1. ✅ `kind` + Inference Gateway up, reproducible from `README.md` (`make up`).
2. ✅ One captured request routed through the gateway to the backend (200 + JSON).
3. ✅ "vLLM vs SGLang" section: both OpenAI-compatible ⇒ client identical; the
  `make swap` output is the artifact. SGLang's RadixAttention tends to win on
   shared-prefix / multi-turn; vLLM wins on ecosystem breadth. Real numbers = Phase 2.
4. ✅ "Phase 2 / GPU benchmark" section stating exactly what would be measured.

---

## 7. Stretch goals (only if time remains)

- **SGLang swap** (`make swap`) — the headline portability artifact. *Caveat,
stated honestly in the README:* upstream ships no SGLang **sim**, so we reuse
the inference-sim relabeled `engine=sglang`. This proves the **Kubernetes-level
portability claim** (identical client, server-side swap), **not** SGLang runtime
behavior. The runtime comparison is the Phase-2 GPU benchmark.
- **A/B / model-aware routing** (`make ab`) — both engines behind one pool.
- **OpenTelemetry trace** on the request path — ties to prior Kubeflow OTel work.

---

## 8. Phase 2 (deferred, needs budget)

A single real benchmark — **vLLM vs SGLang on Llama-3.1-8B**, ~2 hrs on one spot
GPU — turns "I wired it up" into "I measured it." Measure: tokens/sec, TTFT,
p50/p95/p99 latency, throughput under shared-prefix vs unique-prompt workloads
(where RadixAttention should show). Swap `*-sim-deployment.yaml` for the upstream
`vllm/gpu-deployment.yaml` and `sglang/gpu-deployment.yaml`; the gateway wiring is
unchanged. **Deferred because the sim emulates the protocol, not GPU performance.**

---

## 9. Risks & mitigations


| Risk                                     | Mitigation                                                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Helm/chart values drift across releases  | versions pinned in `lib.sh`; scripts use `helm upgrade --install`; README links the guide for the pinned tag |
| EPP / Gateway not "Programmed" in time   | scripts `kubectl wait` with timeouts + print diagnostics on failure                                          |
| EPP `/metrics` requires a token          | default observability scrapes the **sim** pod (token-free); EPP path documented as optional                  |
| arm64 (Apple Silicon) image availability | sim + Istio publish arm64; istioctl download auto-detects arch                                               |
| CRD names change between versions        | `02-install-gateway.sh` warns + points at `kubectl get crd                                                   |


---

## 10. Definition of done

- `make preflight && make up` is green from a clean machine (after `brew install kind helm` + Docker running).
- `make swap` shows the same curl returning 200 from `engine=sglang`.
- `README.md` contains the captured 200 response and a `/metrics` excerpt.
- Repo is self-contained, pinned, and reproducible.

