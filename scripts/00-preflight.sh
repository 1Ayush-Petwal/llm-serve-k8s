#!/usr/bin/env bash
# Preflight: verify the host has everything needed. Read-only, safe to re-run.
source "$(dirname "$0")/lib.sh"

log "Preflight checks"
fail=0

check() { # check <cmd> <hint>
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1 — $($1 version --client 2>/dev/null | head -1 || $1 --version 2>/dev/null | head -1)"
  else
    err "$1 missing — $2"; fail=1
  fi
}

check docker  "install Docker Desktop"
check kubectl "brew install kubectl"
check kind    "brew install kind"
check helm    "brew install helm   (needed: InferencePool is a Helm chart)"
check curl    "comes with macOS"
check envsubst "brew install gettext"

log "Checking Docker daemon"
if docker info >/dev/null 2>&1; then
  ok "Docker daemon reachable"
else
  err "Docker daemon not running — start Docker Desktop, then re-run"; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  ok "All prerequisites satisfied. Next: make up"
else
  die "Preflight failed — install the items marked ✗ above and re-run: make preflight"
fi
