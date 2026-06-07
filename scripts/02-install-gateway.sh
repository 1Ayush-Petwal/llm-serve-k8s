#!/usr/bin/env bash
# Step 2 — control plane:
#   (a) Gateway API CRDs
#   (b) Istio with the inference-extension ext-proc enabled
#   (c) Gateway API Inference Extension CRDs (InferencePool, InferenceObjective)
# Idempotent; safe to re-run.
source "$(dirname "$0")/lib.sh"
require kubectl
require curl

# (a) Gateway API CRDs -------------------------------------------------------
log "Installing Gateway API CRDs ($GATEWAY_API_RELEASE)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_RELEASE}/standard-install.yaml"
ok "Gateway API CRDs applied"

# (b) Istio (provider) -------------------------------------------------------
if [ "$GATEWAY_PROVIDER" != "istio" ]; then
  warn "GATEWAY_PROVIDER=$GATEWAY_PROVIDER — this script only automates 'istio'."
  warn "See https://gateway-api-inference-extension.sigs.k8s.io/guides/ for $GATEWAY_PROVIDER."
fi

if [ ! -x "$ISTIOCTL" ]; then
  log "Downloading istioctl $ISTIO_VERSION into .istio/ (gitignored)"
  mkdir -p "$ROOT/.istio"
  ( cd "$ROOT/.istio" && curl -fsSL https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh - )
  [ -x "$ISTIOCTL" ] || die "istioctl not found at $ISTIOCTL after download"
fi
ok "istioctl: $("$ISTIOCTL" version --remote=false 2>/dev/null || echo "$ISTIO_VERSION")"

log "Installing Istio control plane with ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true"
"$ISTIOCTL" install -y \
  --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
kubectl -n istio-system rollout status deploy/istiod --timeout=180s
ok "Istio ready"

# (c) Inference Extension CRDs ----------------------------------------------
log "Installing Inference Extension CRDs ($IGW_RELEASE)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${IGW_RELEASE}/manifests.yaml"
kubectl wait --for=condition=Established --timeout=60s \
  crd/inferencepools.inference.networking.k8s.io \
  crd/inferenceobjectives.inference.networking.x-k8s.io 2>/dev/null || \
  warn "CRD names may differ in $IGW_RELEASE — check 'kubectl get crd | grep inference'"
ok "Inference Extension CRDs established"

echo
ok "Control plane up. Next: make backend"
