#!/usr/bin/env bash
# Step 4 — wire the gateway to the backend:
#   - InferencePool + Endpoint-Picker (Helm chart)
#   - Gateway (Istio)
#   - HTTPRoute (Gateway -> InferencePool)
#   - InferenceObjective (serving priority)
# Idempotent (helm upgrade --install + kubectl apply).
source "$(dirname "$0")/lib.sh"
require kubectl
require helm "brew install helm"
require envsubst "brew install gettext"

# 1) InferencePool + EPP via the official OCI Helm chart -----------------------
log "Installing InferencePool '$POOL_NAME' + Endpoint-Picker (Helm $IGW_RELEASE)"
helm upgrade --install "$POOL_NAME" \
  --version "$IGW_RELEASE" \
  --namespace "$NAMESPACE" \
  --set inferencePool.modelServers.matchLabels.app="$POOL_LABEL_APP" \
  --set provider.name="$GATEWAY_PROVIDER" \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool
ok "InferencePool chart installed"

# 2) Gateway -----------------------------------------------------------------
log "Applying Gateway '$GATEWAY_NAME'"
k apply -f "$ROOT/manifests/gateway-istio.yaml"

# 3) HTTPRoute + 4) Objective ------------------------------------------------
log "Applying HTTPRoute + InferenceObjective"
envsubst < "$ROOT/manifests/httproute.yaml"          | k apply -f -
envsubst < "$ROOT/manifests/inference-objective.yaml" | k apply -f -

# Wait for the data plane to be programmed -----------------------------------
log "Waiting for Endpoint-Picker rollout"
k rollout status "deploy/${POOL_NAME}-epp" --timeout=180s 2>/dev/null || \
  warn "EPP deploy name may differ; check 'kubectl -n $NAMESPACE get deploy'"

log "Waiting for Gateway to be Programmed"
k wait --for=condition=Programmed "gateway/$GATEWAY_NAME" --timeout=120s || \
  warn "Gateway not Programmed yet; check 'kubectl -n $NAMESPACE describe gateway/$GATEWAY_NAME'"

echo
k get gateway,httproute,inferencepool,inferenceobjective 2>/dev/null
echo
ok "Gateway wired to pool. Next: make test"
