# LLM Serving on Kubernetes — Inference Gateway PoC
# Run `make` (or `make help`) for the menu. Scripts live in ./scripts.

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help preflight cluster control-plane backend gateway test metrics up swap ab down clean

help: ## Show this menu
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Typical flow:  make preflight  &&  make up  &&  make swap"

preflight: ## Verify host tooling (docker/kind/kubectl/helm) and Docker daemon
	@./scripts/00-preflight.sh

cluster: ## Create the kind cluster + namespace
	@./scripts/01-cluster-up.sh

control-plane: ## Install Gateway API CRDs + Istio + Inference Extension CRDs
	@./scripts/02-install-gateway.sh

backend: ## Deploy the vLLM (simulated) backend
	@./scripts/03-deploy-backend.sh

gateway: ## Wire Gateway -> InferencePool + EPP + HTTPRoute + Objective
	@./scripts/04-wire-gateway.sh

test: ## Send an OpenAI-shaped request through the gateway (the milestone)
	@./scripts/05-smoke-test.sh

metrics: ## Scrape backend / EPP Prometheus metrics
	@./scripts/06-observability.sh

up: cluster control-plane backend gateway test ## Full bring-up end-to-end

swap: ## STRETCH: swap vLLM -> SGLang, re-run the identical client
	@./scripts/swap-to-sglang.sh

ab: ## STRETCH: run BOTH engines behind one pool (model-aware A/B)
	@KEEP_VLLM=1 ./scripts/swap-to-sglang.sh

down: ## Delete the kind cluster (full teardown)
	@./scripts/99-teardown.sh

clean: ## Soft teardown: remove workloads, keep the cluster
	@SOFT=1 ./scripts/99-teardown.sh
