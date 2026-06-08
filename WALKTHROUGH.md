# Walkthrough — what this project teaches, proves, and how to show it

> `README.md` is *how to run it*. `IMPLEMENTATION_PLAN.md` is *how it was designed*.
> This file is *what it means* — the concepts behind it, what it proves (and what it
> deliberately doesn't), the demo script, and the recruiter/interview talking points.

---

## 1. What is the exact build about :

This is an **OpenAI-compatible LLM serving path on Kubernetes**, fronted by the
**Gateway API Inference Extension** (the `kubernetes-sigs` / `llm-d` project that is
the current, standards-track answer to "how do I route LLM traffic on K8s"). A
request hits an Istio **Gateway**, an **HTTPRoute** points it at an **InferencePool**,
and an **Endpoint-Picker (EPP)** — a model- and load-aware `ext-proc` service —
chooses which backend pod serves it. The backends are vLLM and SGLang model servers
that expose the **same OpenAI API** and carry the **same pool label**, which is what
makes swapping engines a pure server-side change with an identical client. The whole
thing runs locally on `kind` for **$0** using the `llm-d` inference **simulator** (no
GPU, no weights).

---

## 2. The mental model / Architecture

```
client (plain OpenAI curl)  ──►  Gateway (Istio)  ──►  HTTPRoute  ──►  InferencePool
                                                                            │
                                                          Endpoint-Picker (EPP, ext-proc)
                                                          scores pods on queue depth,
                                                          KV-cache, prefix-cache …
                                                                            │
                                                   ┌────────────────────────┴───────────┐
                                                   ▼                                     ▼
                                        vllm-llama3-8b pods                   sglang-llama3-8b pods
                                        (app=llama3-8b)                       (app=llama3-8b)
```

The single idea the architecture is built around: **both engines wear the same label
`app=llama3-8b`.** Because the pool selects on that label, the Pool / EPP / HTTPRoute /
Gateway never change when you swap or mix engines — and neither does the client.

---

## 3. Core concepts involved :


| Concept                                         | What it is                                                                                                     | Why it matters                                                                                          | Where                                                                                |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| **OpenAI-compatible serving as a K8s workload** | The model server speaks the OpenAI HTTP API and runs as a Deployment                                           | The client is portable across *any* OpenAI-compatible engine                                            | `manifests/*-sim-deployment.yaml`                                                    |
| **Gateway API Inference Extension**             | `InferencePool` + `InferenceObjective` + `HTTPRoute` — LLM-aware routing CRDs                                  | This is the modern, vendor-neutral replacement for hand-rolled Service/Ingress LLM routing              | `manifests/httproute.yaml`, `inference-objective.yaml`, `scripts/04-wire-gateway.sh` |
| **Endpoint-Picker (EPP)**                       | An `ext-proc` callout the Gateway makes per request; scores pods (queue, KV-cache, prefix-cache) and picks one | This is *model-aware* load balancing — round-robin is wrong for LLMs because requests are wildly uneven | EPP Deployment `llama3-8b-pool-epp` (Helm)                                           |
| **Backend portability**                         | vLLM ↔ SGLang is a Deployment swap, same label, same client                                                    | The headline claim recruiters screen for: "vLLM/SGLang serving + k8s"                                   | `scripts/swap-to-sglang.sh`, `manifests/sglang-sim-deployment.yaml`                  |
| **Mixed-engine A/B**                            | Leave both engines up; one pool load-balances across both                                                      | Proves the routing layer is engine-agnostic; enables canary/A-B                                         | `make ab` (captured run in README)                                                   |
| **Observability**                               | vLLM-style Prometheus `/metrics` (latency histograms, token counters, KV-cache)                                | These are the *same* signals EPP routes on and a benchmark would chart                                  | `scripts/06-observability.sh`                                                        |
| **The simulator boundary**                      | The backend emulates the OpenAI *protocol* + metrics, not GPU work                                             | Lets the entire K8s story run for $0 in CI; the honest line between "wired" and "measured"              | `ghcr.io/llm-d/llm-d-inference-sim`                                                  |


---

## 4. What it represents / depicts (the "so what")

- **It depicts the K8s-native LLM serving stack as it actually looks in 2026** — not a
toy Flask app behind an Ingress, but the Gateway API Inference Extension that
`llm-d` / KServe / production platforms are standardizing on.
- **It represents the half of "vLLM/SGLang serving + k8s" that is hard and
differentiating**: the operator/CRD/routing muscle. Most candidates can `pip install vllm`; far fewer can wire an InferencePool + EPP and explain *why* model-aware
routing beats round-robin.
- **It proves a real, falsifiable claim** — that engine choice is a server-side
decision — with captured evidence (a 200 through the gateway, an A/B split across
both engines, real Prometheus series), not assertions.

---

## 5. What it does NOT prove right now, real runtime behaviour ( in progress ) :

The backends are the **same simulator image relabeled** — so the project proves the
**Kubernetes-level** portability and routing story, **not** the engines' **runtime
behavior**. It has never executed real PagedAttention or RadixAttention, has no real
tokens/sec, TTFT, or prefix-cache wins. That is the **one** gap, and it is the entire
content of "Phase 2" (a real GPU benchmark). Disclosing this *first* is what makes the
rest credible — see the README "Honesty note."

---

## 6. The demo script (what to run, what to point at)

A 2–3 minute sequence — record it (see §7), or run it live in an interview:

```bash
make up        # cluster → CRDs+Istio → backend → gateway → 200 OK
#   ▶ point at: "Gateway Programmed", EPP Ready, and the captured 200 JSON

make swap      # vLLM → SGLang, SAME curl, still 200
#   ▶ point at: only the Deployment changed; Pool/EPP/Route/Gateway/client untouched

make ab        # both engines behind one pool
#   ▶ then send a burst and show the split — README "Captured A/B run" (vLLM/SGLang)

make metrics   # real vLLM Prometheus series from a backend pod
#   ▶ point at: these are what EPP scores on, and what Phase-2 would chart
```

The line to say out loud: *"The client is plain OpenAI and never changes. Everything*  
*interesting happens server-side, in the InferencePool and the Endpoint-Picker."*

---

## 7. Do you need to script/record a demo? — Yes.

**Recommended.** ~95% of recruiters and reviewers will not `git clone` and `make up`.
A short recording puts the proof in the 90 seconds they actually spend:

- **Format:** [asciinema](https://asciinema.org) for crisp, copy-pasteable terminal
fidelity (embeds in a README), or a Loom/screen-recording with a one-line voiceover
per step if you want a face/voice.
- **Length:** keep it under 3 minutes; follow the §6 script exactly, no detours.
- **Where it lives:** link it at the top of the README and in your DM/portfolio blurb.
- **Pair it with words:** read the §6.1 narration verbatim over the recording; the §8
talking points are the longer-form version for live Q&A.

It is the single highest-leverage thing you can add *without spending anything* — more
impactful per-minute than most additional code.

---

## 8. Recruiter / interview talking points

**The 30-second pitch:**

> "I built an OpenAI-compatible LLM serving path on Kubernetes behind the Gateway API
> Inference Extension — InferencePool, InferenceObjective, and an Endpoint-Picker doing
> model-aware routing — and showed that swapping vLLM for SGLang is a server-side change
> with an identical client. It runs for $0 on kind using the llm-d simulator; the real
> GPU throughput benchmark is the documented next step."

**QNAs:**

- *"Is this real inference?"* → "No — the backend emulates the OpenAI protocol and
metrics so the whole K8s story runs for free in CI. The real-engine GPU benchmark is
Phase 2, scoped in the plan; the wiring is identical when you swap the sim for a GPU
deployment."
- *"Why not just round-robin?"* → "LLM requests are wildly uneven — prompt length, KV-
cache state, queue depth. The EPP scores pods on exactly those signals, which is why
the Inference Extension exists instead of a vanilla Service."
- *"What's the difference between vLLM and SGLang?"* → "Same OpenAI API, so the client
is identical and it's a server-side choice. SGLang's RadixAttention tends to win on
shared-prefix / multi-turn; vLLM has broader model + ecosystem coverage. The real
numbers need a GPU — that's Phase 2."
- *"What was hard?"* → "Fitting the EPP onto a single kind node, getting the Gateway to
`Programmed` without a cloud LB (ClusterIP-backed Istio service), and proving the A/B
split with real per-pod metric deltas rather than just asserting it."

---

## 9. Phase 2 in one line

A ~2-hour run of **real vLLM vs SGLang on Llama-3.1-8B on one GPU** turns "I wired it
up" into "I measured it." It costs ~$7 of GPU time and the gateway wiring is unchanged.
See `IMPLEMENTATION_PLAN.md` §8 and the README "Phase 2" section for exactly what would
be measured and how to fund it with the GitHub Student Pack DigitalOcean credit.