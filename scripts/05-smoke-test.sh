#!/usr/bin/env bash
# Step 5 — send an OpenAI-shaped request THROUGH the gateway. This is the
# milestone: a 200 routed gateway -> EPP -> backend pod.
source "$(dirname "$0")/lib.sh"
require kubectl
require curl

# Discover the Service Istio created for the Gateway (named "<gw>-istio").
SVC="$(k get svc -l "gateway.networking.k8s.io/gateway-name=$GATEWAY_NAME" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$SVC" ] || SVC="${GATEWAY_NAME}-istio"
log "Gateway service: $SVC (namespace $NAMESPACE)"

LPORT="${LPORT:-8080}"
log "Port-forwarding svc/$SVC $LPORT:80"
k port-forward "svc/$SVC" "$LPORT:80" >/tmp/llm-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID >/dev/null 2>&1 || true' EXIT

# wait for the forward to come up
for i in $(seq 1 20); do
  curl -fsS "http://localhost:$LPORT/" >/dev/null 2>&1 && break || sleep 0.5
done

echo
log "POST /v1/completions  model=$MODEL_NAME"
HTTP_CODE=$(curl -sS -o /tmp/llm-resp.json -w '%{http_code}' \
  "http://localhost:$LPORT/v1/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_NAME\",\"prompt\":\"hello from the inference gateway\",\"max_tokens\":16}")

echo "HTTP $HTTP_CODE"
if command -v jq >/dev/null 2>&1; then jq . /tmp/llm-resp.json; else cat /tmp/llm-resp.json; fi
echo
if [ "$HTTP_CODE" = "200" ]; then
  ok "MILESTONE: 200 OK routed through the Inference Gateway to a backend pod."
else
  die "Expected 200, got $HTTP_CODE. Inspect: kubectl -n $NAMESPACE get gateway,httproute,inferencepool; cat /tmp/llm-pf.log"
fi
