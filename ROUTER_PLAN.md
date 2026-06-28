# ROUTER_PLAN.md — InferGate Request Router

> Design + build plan for a **concurrent, model-/prefix-aware LLM request router** (Go)
> that sits in front of the vLLM/SGLang replicas in this repo.
>
> This document is the contract for the four resume bullets. Every claim there maps to a
> milestone here; don't put a bullet on a resume until its milestone is merged and you can
> whiteboard it.

---

## 0. Why this exists (and what it proves)

The current repo wires together off-the-shelf Kubernetes pieces (Gateway API Inference
Extension + upstream Endpoint-Picker). That demonstrates *integration*. This router
demonstrates *engineering*: it is a non-trivial service you author in a general-purpose
language that exercises concurrency, real data structures, distributed-systems concerns, and
measured performance.

Mapping to the qualifications it targets:

| Capability | Where it lives in this plan |
|---|---|
| General-purpose language | Go (`cmd/`, `internal/`) |
| Concurrency / multi-threading / synchronization | Worker pool, conn pool, `context` cancellation, background health/scrape goroutines, **synchronized load store + prefix index** (§4) |
| Data structures + algorithms | Routing policies: round-robin, P2C, consistent hashing w/ bounded loads, **radix-tree prefix routing** (§5) |
| Design + implement a complex system | The whole service (§3 architecture) |
| Performance / reliability / data analysis / visualization / debugging | Load generator, p50/p95/p99 + TTFT + throughput, circuit breaker / retries / backpressure, Prometheus + Grafana (§6, §7) |

---

## 1. Scope & non-goals

**In scope.** A standalone HTTP service that accepts OpenAI-compatible `/v1/completions` and
`/v1/chat/completions`, picks a backend replica per request using a pluggable policy, proxies
the request, tracks live load, and survives backend failures.

**Non-goals (be honest about these in the README too).**
- The router does **not** run the model. It routes to the existing simulated (or, in Phase 2,
  GPU) backends.
- On the **simulator** there is no real KV cache, so prefix-aware routing cannot show a *real*
  TTFT win out of the box. You handle this two ways (see §6.3): (a) measure what *is* real on
  the sim — load spread, tail latency under skew, routing overhead, decision correctness — and
  (b) inject a *modeled* prefix-cache latency discount so the algorithm can be demonstrated
  end-to-end, clearly labeled as a model. The true cache win is the Phase-2 GPU run.

---

## 2. Where it sits in the request path

```
client ──▶ InferGate router ──▶ backend replica (vllm-sim / sglang-sim)
              │  picks replica          (Service or direct pod IPs)
              │  tracks load
              │  health-checks
              └─ scrapes /metrics
```

- **Milestone 1–4:** run the router as a plain reverse proxy in front of the backend pods
  (bypass the gateway). Simplest path to real Go in the request path.
- **Milestone 5 (optional):** repackage the same routing core as a Gateway **ext-proc
  Endpoint-Picker** (gRPC) so it lives *inside* the gateway path instead of beside it. The
  policy/load-store code is reused unchanged — that's the payoff of the interface boundary.

---

## 3. Package layout

```
router/
├── cmd/
│   ├── router/main.go        # config, wire-up, start server + background workers
│   └── loadgen/main.go       # benchmark load generator (your code)
├── internal/
│   ├── server/               # OpenAI-compatible HTTP handlers
│   ├── proxy/                # dispatch to backend, connection pool, streaming
│   ├── routing/
│   │   ├── policy.go         # Policy interface + Request/Backend types
│   │   ├── roundrobin.go
│   │   ├── p2c.go            # power-of-two-choices least-load
│   │   ├── consistenthash.go # consistent hashing w/ bounded loads
│   │   ├── prefix.go         # prefix-aware policy (uses radix)
│   │   └── radix/            # the radix tree data structure + tests
│   ├── loadstore/            # synchronized live-load store
│   ├── health/               # background health checks + /metrics scrape
│   ├── reliability/          # circuit breaker, retry budget, backpressure
│   ├── metrics/              # prometheus collectors
│   └── config/               # env/flags
├── deploy/                   # router Deployment/Service + grafana dashboard JSON
└── bench/                    # methodology.md, results tables, dashboard exports
```

---

## 4. Core types & the concurrency model

### 4.1 Interfaces (start here — type-driven design)

```go
// Backend is a servable replica.
type Backend struct {
    ID     string // stable id, e.g. pod name
    Addr   string // host:port
    Engine string // "vllm" | "sglang"
}

// Request carries only what a Policy needs to decide.
type Request struct {
    Model  string
    Prompt string // chat messages normalized to a single prefix string
    Key    string // optional affinity key (session/user); empty = none
}

// Policy chooses one backend from healthy candidates. Pure-ish: no I/O.
type Policy interface {
    Pick(ctx context.Context, req *Request, candidates []*Backend) (*Backend, error)
    Name() string
}
```

Keeping `Policy` free of network I/O is the design decision that makes milestone 5 (ext-proc
reuse) and unit testing both trivial. Say that in interviews.

### 4.2 The synchronized load store (this is your synchronization story)

```go
type Stat struct {
    InFlight      int64
    QueueDepth    int64   // scraped from backend /metrics
    Healthy       bool
    LastLatencyMs float64
}

type LoadStore interface {
    Incr(id string)                 // on dispatch
    Decr(id string)                 // on completion (defer)
    Get(id string) Stat
    Snapshot() map[string]Stat      // for P2C / least-load
    SetHealth(id string, ok bool)
    UpdateQueueDepth(id string, d int64)
}
```

Implementation progression — **build all three and benchmark them; that's the interview gold:**
1. `mutexStore` — one `sync.RWMutex` around a `map[string]*Stat`. Correct, simple, contended.
2. `shardedStore` — N shards keyed by `fnv(id) % N`, each with its own `RWMutex`. Cuts
   contention.
3. `atomicStore` — per-backend `InFlight` as `atomic.Int64`, no lock on the hot Incr/Decr
   path; lock only for membership changes.

You will be able to show, with the load generator, how p99 and router overhead change across
these three under high concurrency. That single graph answers "tell me about a time you
reasoned about synchronization."

### 4.3 Request lifecycle (the goroutine/worker story)

- **Bounded concurrency.** A counting semaphore (`chan struct{}` of size `maxInFlight`) caps
  total in-flight work. Acquire on entry; release on completion. Full → backpressure (§7.3).
- **Per-request goroutine**, but bounded by the semaphore (not unbounded spawning).
- **`context` everywhere.** Per-request `context.WithTimeout`; cancellation propagates to the
  outbound proxy call so a client disconnect or deadline frees the backend slot immediately.
- **Connection pooling.** One tuned `http.Transport` (set `MaxIdleConnsPerHost`,
  `MaxConnsPerHost`, idle timeouts) shared across requests — do **not** make a new client per
  request.
- **Background workers (separate goroutines, started in `main`):**
  - health checker: pings each backend on an interval, calls `SetHealth`.
  - metrics scraper: pulls backend `/metrics`, calls `UpdateQueueDepth`.
  - both exit cleanly on a shared `context` cancel for graceful shutdown.

Acceptance for the "concurrency/synchronization" bullet: the race detector (`go test -race`,
`go run -race`) is clean under the load generator at high concurrency.

---

## 5. Routing policies (the data-structures + algorithms bullet)

Build in this order; each is a separate file implementing `Policy`.

### 5.1 Round-robin — baseline
`atomic.Uint64` counter mod len(candidates). O(1). Exists to be the control in benchmarks.

### 5.2 Power-of-two-choices (P2C) least-load
Pick 2 distinct random candidates, route to the one with fewer `InFlight` (from `LoadStore`).
O(1), provably tight load spread vs. global-least-load's O(n) scan and herd behavior. This is
your default once load tracking exists.

### 5.3 Consistent hashing with bounded loads
Hash ring keyed by `Request.Key` (or prefix hash if no key) for **affinity**; if the target is
over the load bound `avg * (1+ε)`, walk the ring to the next replica. Gives cache-friendly
stickiness *and* bounded skew. Cite the bounded-loads idea; implement the ring with a sorted
`[]uint64` + `sort.Search` (binary search) — that's a clean DSA talking point on its own.

### 5.4 Prefix-aware routing — the centerpiece

**Goal.** Send requests that share a long prompt prefix to the *same* replica, so the second
one reuses the first's cached KV (RadixAttention / prefix cache) → lower TTFT.

**Data structure — `radix.PrefixIndex`:** a radix tree (compressed trie) over prompt prefixes.
Each node records which replicas recently served a request passing through it (so they likely
hold that prefix in cache), with timestamps for eviction.

```go
type node struct {
    edge     string             // compressed edge label
    children map[byte]*node
    replicas map[string]int64   // replicaID -> lastSeen (unixnano)
}

type PrefixIndex struct {
    mu   sync.RWMutex           // start here; shard later if it's hot
    root *node
    cap  int                    // max nodes; evict LRU leaves past this
    // + intrusive LRU list for O(1) eviction
}

// Match walks the prompt, returns replicas tagged on the DEEPEST node whose
// matched prefix length >= minPrefixLen. Empty result => no warm candidate.
func (p *PrefixIndex) Match(prompt string, minPrefixLen int) []string

// Record inserts the prompt's prefix and tags chosen on the terminal node;
// bumps LRU; evicts if over cap.
func (p *PrefixIndex) Record(prompt, chosen string)
```

**Pick algorithm:**
1. `cands := index.Match(req.Prompt, minPrefixLen)` — replicas with a likely warm cache.
2. Intersect `cands` with currently-healthy candidates.
3. If non-empty → among them pick **least-loaded** (reuse P2C logic). Cache locality *and*
   load awareness.
4. If empty → fall back to P2C (§5.2). Never route blindly.
5. After dispatch, `index.Record(req.Prompt, chosen.ID)`.

**Eviction.** KV caches are finite and the backend evicts on its own; your index must not grow
unbounded or claim stale warmth. Cap node count, evict LRU. Tune `minPrefixLen` so trivially
short shared prefixes (e.g. a 5-char greeting) don't cause false affinity.

**Concurrency.** Read-heavy on `Match`, write on `Record`. Start with the single `RWMutex`;
if the benchmark shows it as the bottleneck, shard the tree by the first byte of the prompt
(N independent subtrees, N locks). This is the second half of your synchronization story.

Unit tests for the radix tree (insert/match/evict, edge splitting, the false-affinity guard)
are non-negotiable — they're cheap and they're the proof you actually built it.

---

## 6. Benchmarking (the performance / data-analysis bullet)

### 6.1 Load generator — `cmd/loadgen` (your code, not `wrk`/`k6`)
Writing your own is the point; it shows you can build a measurement harness.

- Flags: `-c` concurrency, `-n` total requests (or `-d` duration), `-rate` for open-loop,
  `-workload {shared-prefix|unique|mixed}`, `-policy` (to label output).
- **Open-loop** option (fixed arrival rate) so you measure latency under load, not just a
  closed-loop fixpoint — this distinction matters and interviewers notice it.
- Records per-request: queued→dispatched→first-byte→complete. Computes **TTFT** (first byte),
  end-to-end p50/p95/p99, throughput (req/s and tokens/s), error rate.
- Emits a CSV/markdown table per run.

### 6.2 Workloads
- **shared-prefix:** a long fixed system prompt + short varying suffix (simulates multi-turn /
  agentic / RAG-with-same-context traffic — where prefix routing should win).
- **unique:** random prompts, no shared prefix (control; prefix routing should ≈ P2C, and you
  must show it doesn't *hurt*).
- **mixed:** realistic blend; also use it to test skew (a few hot prefixes).

### 6.3 What you can honestly measure on the simulator
The sim emulates the protocol, not GPU/KV behavior, so on it you report:
- **Real, no asterisk:** load spread / tail latency under skew across the three lock
  strategies; routing overhead (added latency the router itself costs); P99 under a hot-key
  workload; correctness (prefix-affinity hit rate from your own metrics); graceful behavior
  under injected backend failures.
- **Modeled, labeled:** add a `-prefix-cache-discount` mode to the loadgen (or a sidecar) that
  *reduces* simulated TTFT when a request lands on a replica that recently served its prefix —
  lets you demonstrate the algorithm end-to-end. Label it clearly as a model in `bench/`.
- **Phase 2 (GPU):** the true tokens/sec + TTFT win for prefix routing on real vLLM/SGLang.
  Keep this as the stated next step, exactly like the repo already frames it.

Put a results table + the methodology in `bench/methodology.md`. A table comparing the four
policies × three workloads is the artifact that turns "I built a router" into "I measured it."

---

## 7. Reliability (the reliability/debugging bullet)

### 7.1 Health checking
Background goroutine per the model in §4.3; unhealthy backends are excluded from candidates by
every policy (they filter on `Stat.Healthy`).

### 7.2 Circuit breaker (per backend)
Three-state machine: **closed → open** on consecutive failures or an error-rate threshold over
a rolling window; **open → half-open** after a cooldown; **half-open → closed** on a successful
probe, back to **open** on failure. An open breaker removes the backend from candidates.

### 7.3 Retries + backpressure
- Retry only **idempotent-safe / retriable** failures (connection refused, 503, timeout
  before any bytes), on a **different** replica, capped (e.g. 2).
- **Retry budget** (e.g. retries ≤ 10% of requests over a window) to prevent retry storms from
  amplifying an outage — call this out; it's the senior-sounding detail.
- Backpressure: when the global semaphore is full, return `429` immediately (or enqueue in a
  bounded queue with its own timeout). Never buffer unboundedly.

### 7.4 Graceful shutdown
On SIGTERM: stop accepting new requests, cancel background workers' context, drain in-flight
with a deadline. Important for "production-grade" framing and trivial to demo with `kubectl
delete pod`.

---

## 8. Observability (the visualization bullet)

**Prometheus metrics the router exports:**
- `infergate_requests_total{policy,backend,code}` — counter
- `infergate_request_duration_seconds{policy,backend}` — histogram (for p50/95/99)
- `infergate_ttft_seconds{policy,backend}` — histogram
- `infergate_inflight{backend}` — gauge
- `infergate_route_decisions_total{policy,result}` — `result ∈ {prefix_hit, fallback}`
- `infergate_breaker_state{backend}` — gauge (0/1/2)
- `infergate_retries_total`, `infergate_backpressure_rejections_total` — counters

**Grafana dashboard (`deploy/grafana-dashboard.json`):** p50/p95/p99 latency, throughput,
per-backend in-flight, **prefix-cache hit rate**, breaker states, error/retry/rejection rates.
Export the JSON into the repo so it renders for reviewers without your cluster.

---

## 9. Milestones (build order + acceptance criteria)

> Each milestone is independently resume-true. Ship in order; don't claim a bullet before its
> milestone is merged.

| # | Milestone | Done when… | Unlocks resume bullet |
|---|---|---|---|
| 1 | **Scaffold**: Go HTTP server, OpenAI-compatible, reverse-proxy to backends, round-robin, connection pool, `context` timeouts | `make up` + your router returns 200 routed through *your* code; repo language flips to mostly Go | bullet 1 (partial) |
| 2 | **Concurrency core**: semaphore-bounded worker model, load store (all 3 impls), background health + scrape goroutines, graceful shutdown | `go run -race` clean under loadgen at high `-c`; unhealthy backend excluded within one health interval | bullet 1 (full) |
| 3 | **Algorithms**: P2C, consistent-hash w/ bounded loads, radix prefix policy + unit tests | prefix policy beats round-robin on shared-prefix workload in your modeled run; all policies pass tests | bullet 2 |
| 4 | **Perf + reliability**: loadgen with TTFT/p50/95/99/throughput, circuit breaker, retry budget, backpressure, Prometheus + Grafana JSON, `bench/methodology.md` + results table | a 4×3 (policy×workload) results table is committed; killing a backend pod mid-load shows breaker trip + recovery in Grafana | bullet 3 |
| 5 | **(Optional flex)** repackage routing core as ext-proc EPP **or** rewrite the radix tree / hot path in Rust or C++ **or** ship the lock-strategy benchmark writeup | the reused policy code runs inside the gateway path, or the alt-language module passes the same tests | interview depth |

---

## 10. Interview talking points (so this doc doubles as prep)

- **Why P2C over global-least-load?** O(1) vs O(n), and global-least-load causes herding —
  everyone picks the same "least loaded" replica simultaneously and overloads it.
- **Why a radix tree, not a hash map of full prompts?** Prompts share *prefixes*, not whole
  strings; the tree finds the longest cached prefix and is memory-compressed. A full-prompt
  hash gives zero reuse across near-identical prompts.
- **How do you keep the load store correct under concurrency?** Walk them through mutex →
  sharded → atomic, with the benchmark that justified the choice. Mention the race detector.
- **What's the failure story?** Health checks + circuit breaker remove bad backends; retry
  *budget* prevents retry storms; backpressure (429) instead of unbounded queuing.
- **What's real vs modeled in your benchmarks?** Be the one who volunteers the honesty: load
  spread and overhead are real on the sim; the prefix-cache TTFT win is modeled here and
  measured for real on GPU in Phase 2.
- **What would you do next?** Phase-2 GPU benchmark; shard the prefix tree; KV-cache-utilization
  scraped from the backend feeding the bounded-load threshold.

---

## 11. First commit checklist (start milestone 1 today)

1. `go mod init github.com/1Ayush-Petwal/llm-serve-k8s/router`
2. `internal/routing/policy.go` — paste the interfaces from §4.1.
3. `internal/server` — handler that reads the OpenAI body, builds a `Request`, calls the
   policy, proxies via a shared `http.Transport`.
4. `internal/routing/roundrobin.go` — make 200s flow through your code.
5. Point it at the existing backend Service; confirm `make test`-style curl returns 200 via the
   router. Commit. Repo is now a Go project.
