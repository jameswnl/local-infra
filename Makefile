# Local dev infra — OTel + Jaeger + OpenShell
#
# Podman compose targets manage the local container stack.
# Kind targets manage a Kubernetes cluster with services deployed as pods.

KIND_CLUSTER    ?= local-infra
KIND_KUBECONFIG ?= $(CURDIR)/kind/kubeconfig
KUBECTL         := kubectl --kubeconfig $(KIND_KUBECONFIG)

export KIND_EXPERIMENTAL_PROVIDER=podman

.PHONY: up down logs logs-otel logs-openshell openshell-health jaeger status register help \
        up-openshell down-openshell \
        kind-up kind-down kind-status \
        kind-openshell-up kind-openshell-down kind-openshell-logs kind-openshell-health kind-openshell-register

# ---------- Podman Compose ----------

up:  ## Start everything (OTel + Jaeger + OpenShell)
	podman compose up -d
	@echo ""
	@echo "Jaeger UI:   http://localhost:16686"
	@echo "OTel:        grpc://localhost:4317  http://localhost:4318"
	@echo "OpenShell:   http://localhost:8080"
	@echo ""
	@echo "Register (one-time):  make register"

up-openshell:  ## Start only OpenShell
	podman compose up -d gateway
	@echo ""
	@echo "OpenShell: http://localhost:8080"

down:  ## Stop everything
	podman compose down

down-openshell:  ## Stop only OpenShell
	podman compose down gateway

logs:  ## Tail all logs
	podman compose logs -f

logs-otel:  ## Tail OTel collector logs
	podman compose logs -f otel-collector

logs-openshell:  ## Tail OpenShell logs
	podman compose logs -f gateway

openshell-health:  ## Check OpenShell health
	@curl -sf http://localhost:8081/healthz && echo " OK" || echo " UNHEALTHY"

jaeger:  ## Open Jaeger UI in browser
	@open http://localhost:16686 2>/dev/null || xdg-open http://localhost:16686 2>/dev/null || true

status:  ## Show running containers
	@podman compose ps

register:  ## Register OpenShell with CLI (one-time)
	openshell gateway add http://localhost:8080 --name local-podman

# ---------- Kind: Cluster ----------

kind-up:  ## Create Kind cluster
	@if kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER)$$"; then \
		echo "Cluster '$(KIND_CLUSTER)' already exists"; \
	else \
		echo "[kind] Creating cluster..."; \
		kind create cluster --config kind/kind-config.yaml --wait 60s; \
	fi
	@kind get kubeconfig --name $(KIND_CLUSTER) > $(KIND_KUBECONFIG)
	@echo ""
	@echo "Cluster ready. Deploy services:"
	@echo "  make kind-openshell-up"

kind-down:  ## Delete Kind cluster
	kind delete cluster --name $(KIND_CLUSTER)
	@rm -f $(KIND_KUBECONFIG)

kind-status:  ## Show all pods in Kind cluster
	@$(KUBECTL) get pods -A

# ---------- Kind: OpenShell ----------

kind-openshell-up: kind-up  ## Deploy OpenShell to Kind
	@echo "[kind] Deploying OpenShell..."
	@$(KUBECTL) apply -f kind/openshell-gateway.yaml
	@$(KUBECTL) -n openshell rollout status deployment/openshell-gateway --timeout=120s
	@echo ""
	@echo "OpenShell: http://localhost:9080"
	@echo "Health:    http://localhost:9081/healthz"
	@echo ""
	@echo "Register (one-time):  make kind-openshell-register"

kind-openshell-down:  ## Remove OpenShell from Kind
	$(KUBECTL) delete -f kind/openshell-gateway.yaml --ignore-not-found

kind-openshell-logs:  ## Tail OpenShell logs in Kind
	$(KUBECTL) -n openshell logs -f deployment/openshell-gateway

kind-openshell-health:  ## Check OpenShell health in Kind
	@curl -sf http://localhost:9081/healthz && echo " OK" || echo " UNHEALTHY"

kind-openshell-register:  ## Register Kind OpenShell with CLI (one-time)
	openshell gateway add http://localhost:9080 --name local-kind

# ---------- Help ----------

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
