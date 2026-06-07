#!/usr/bin/env bash
# Step 3 — deploy the vLLM (simulated) backend. No GPU, no weights.
source "$(dirname "$0")/lib.sh"
require kubectl
require envsubst "brew install gettext"

log "Deploying vLLM-sim backend: model='$MODEL_NAME' label app=$POOL_LABEL_APP"
envsubst < "$ROOT/manifests/vllm-sim-deployment.yaml" | k apply -f -

log "Waiting for backend pods to be Ready"
k rollout status "deploy/vllm-${POOL_LABEL_APP}" --timeout=180s

echo
k get pods -l "app=$POOL_LABEL_APP" -o wide
ok "Backend ready (3 replicas). Next: make gateway"
