#!/usr/bin/env bash
# Shared config + helpers for the LLM-serving-on-K8s PoC.
# Source this from every script:  source "$(dirname "$0")/lib.sh"
#
# Every value is overridable from the environment, e.g.:
#   POOL_NAME=my-pool ./scripts/04-wire-gateway.sh

set -euo pipefail

# Resolve this file's dir under bash (BASH_SOURCE) or zsh ($0 when sourced).
if [ -n "${BASH_SOURCE:-}" ]; then _LIB_SELF="${BASH_SOURCE[0]}"; else _LIB_SELF="$0"; fi
LIB_DIR="$(cd "$(dirname "$_LIB_SELF")" && pwd)"
ROOT="$(cd "$LIB_DIR/.." && pwd)"

# ---- Pinned upstream versions (verified live; bump deliberately) ------------
IGW_RELEASE="${IGW_RELEASE:-v1.5.0}"          # gateway-api-inference-extension
GATEWAY_API_RELEASE="${GATEWAY_API_RELEASE:-v1.5.1}"  # sigs.k8s.io/gateway-api CRDs
ISTIO_VERSION="${ISTIO_VERSION:-1.28.0}"      # >=1.28 required for InferencePool v1
SIM_IMAGE="${SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim:v0.8.2}"

# ---- Cluster / naming ------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-llm-serve}"
NAMESPACE="${NAMESPACE:-llm-serving}"
GATEWAY_PROVIDER="${GATEWAY_PROVIDER:-istio}"

# The single label the InferencePool selects on. BOTH the vLLM and SGLang
# backends carry app=$POOL_LABEL_APP, which is what makes the backend swap a
# pure server-side change with an identical client.
POOL_LABEL_APP="${POOL_LABEL_APP:-llama3-8b}"
POOL_NAME="${POOL_NAME:-llama3-8b-pool}"      # = Helm release name = InferencePool name
MODEL_NAME="${MODEL_NAME:-meta-llama/Llama-3.1-8B-Instruct}"  # cosmetic; sim loads no weights
GATEWAY_NAME="${GATEWAY_NAME:-inference-gateway}"

# Local istioctl install location (gitignored)
ISTIO_HOME="${ISTIO_HOME:-$ROOT/.istio/istio-$ISTIO_VERSION}"
ISTIOCTL="$ISTIO_HOME/bin/istioctl"

# ---- Pretty logging --------------------------------------------------------
if [ -t 1 ]; then
  C_RESET="\033[0m"; C_BLUE="\033[1;34m"; C_GREEN="\033[1;32m"
  C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_DIM="\033[2m"
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi
log()  { printf "${C_BLUE}==>${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; }
warn() { printf "${C_YELLOW}!${C_RESET}  %s\n" "$*" >&2; }
err()  { printf "${C_RED}✗${C_RESET}  %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
dim()  { printf "${C_DIM}%s${C_RESET}\n" "$*"; }

# require <cmd> [install-hint]
require() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. ${2:-Install it and re-run.}"
}

# kubectl pinned to our namespace
k() { kubectl -n "$NAMESPACE" "$@"; }

export ROOT NAMESPACE CLUSTER_NAME POOL_NAME POOL_LABEL_APP MODEL_NAME \
       GATEWAY_NAME GATEWAY_PROVIDER IGW_RELEASE GATEWAY_API_RELEASE \
       ISTIO_VERSION SIM_IMAGE
