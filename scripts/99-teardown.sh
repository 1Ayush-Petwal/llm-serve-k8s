#!/usr/bin/env bash
# Tear it all down. By default deletes the whole kind cluster (cleanest).
#   ./scripts/99-teardown.sh            # delete the kind cluster
#   SOFT=1 ./scripts/99-teardown.sh     # keep cluster, remove only our workloads
source "$(dirname "$0")/lib.sh"

if [ "${SOFT:-0}" = "1" ]; then
  require kubectl; require helm
  warn "SOFT teardown — removing workloads, keeping cluster '$CLUSTER_NAME'"
  helm uninstall "$POOL_NAME" -n "$NAMESPACE" 2>/dev/null || true
  k delete -f "$ROOT/manifests/httproute.yaml" --ignore-not-found 2>/dev/null || true
  k delete deploy "vllm-${POOL_LABEL_APP}" "sglang-${POOL_LABEL_APP}" --ignore-not-found
  k delete inferenceobjective default-objective --ignore-not-found 2>/dev/null || true
  k delete gateway "$GATEWAY_NAME" --ignore-not-found 2>/dev/null || true
  ok "Workloads removed (cluster + CRDs + Istio remain)"
else
  require kind
  log "Deleting kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
  ok "Cluster gone. (istioctl cache remains under .istio/ — delete it manually if you like.)"
fi
