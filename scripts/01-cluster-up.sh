#!/usr/bin/env bash
# Step 1 — local kind cluster + namespace. Idempotent.
source "$(dirname "$0")/lib.sh"
require docker "Start Docker Desktop."
require kind   "brew install kind"
require kubectl "brew install kubectl"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "kind cluster '$CLUSTER_NAME' already exists"
else
  log "Creating kind cluster '$CLUSTER_NAME' (~1-2 min)"
  kind create cluster --config "$ROOT/manifests/kind-cluster.yaml" --wait 120s
fi

kubectl cluster-info --context "kind-$CLUSTER_NAME" >/dev/null
ok "kubectl context: kind-$CLUSTER_NAME"

log "Ensuring namespace '$NAMESPACE'"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
ok "Namespace ready: $NAMESPACE"
