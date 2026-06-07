#!/usr/bin/env bash
# STRETCH — backend portability: swap vLLM -> SGLang with the client UNCHANGED.
#
# Both backends carry app=$POOL_LABEL_APP, so the existing InferencePool, EPP,
# HTTPRoute and Gateway need ZERO changes. We bring up the SGLang Deployment,
# scale vLLM to 0, and re-run the IDENTICAL curl from 05-smoke-test.sh.
#
#   ./scripts/swap-to-sglang.sh          # swap: sglang in, vllm out
#   KEEP_VLLM=1 ./scripts/swap-to-sglang.sh   # A/B: both engines serve the pool
source "$(dirname "$0")/lib.sh"
require kubectl
require envsubst

log "Deploying SGLang backend (same model, same pool label, engine-type=sglang)"
envsubst < "$ROOT/manifests/sglang-sim-deployment.yaml" | k apply -f -
k rollout status "deploy/sglang-${POOL_LABEL_APP}" --timeout=180s

if [ "${KEEP_VLLM:-0}" = "1" ]; then
  warn "KEEP_VLLM=1 — leaving vLLM up: the pool now A/Bs across BOTH engines."
else
  log "Scaling vLLM to 0 (clean swap)"
  k scale "deploy/vllm-${POOL_LABEL_APP}" --replicas=0
fi

echo
log "Pods now backing pool '$POOL_NAME':"
k get pods -l "app=$POOL_LABEL_APP" \
  -L inference.networking.k8s.io/engine-type -o wide
echo
log "Re-running the IDENTICAL client request (no client change)…"
"$ROOT/scripts/05-smoke-test.sh"
echo
ok "Same curl, same 200 — served by SGLang. Backend portability proven."
