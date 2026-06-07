#!/usr/bin/env bash
# Step 6 — observability. Scrape Prometheus metrics from the simulated backend
# (OpenAI/vLLM-style series) and, if reachable, the Endpoint-Picker. Token-free
# path first: the sim exposes /metrics directly on its pod.
source "$(dirname "$0")/lib.sh"
require kubectl
require curl

POD="$(k get pods -l "app=$POOL_LABEL_APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$POD" ] || die "No backend pods found (label app=$POOL_LABEL_APP). Run: make backend"

log "Scraping /metrics from backend pod: $POD"
k port-forward "pod/$POD" 8000:8000 >/tmp/llm-metrics-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 20); do curl -fsS http://localhost:8000/metrics >/dev/null 2>&1 && break || sleep 0.5; done

echo "----- backend metrics (filtered) ---------------------------------------"
curl -fsS http://localhost:8000/metrics \
  | grep -Ei 'vllm|request|running|waiting|queue|num_' | grep -v '^#' | head -30 \
  || warn "no matching series yet — send traffic first (make test)"
echo "------------------------------------------------------------------------"

echo
log "Routing decisions live in the Endpoint-Picker. To inspect EPP metrics:"
dim "  kubectl -n $NAMESPACE logs deploy/${POOL_NAME}-epp | tail"
dim "  kubectl -n $NAMESPACE port-forward deploy/${POOL_NAME}-epp 9090:9090  # then curl :9090/metrics"
echo
ok "Captured backend metrics. (Optional full stack: scripts/optional-prometheus.sh)"
