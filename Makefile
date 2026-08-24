# OTel Collector + Jaeger

.PHONY: up down logs jaeger status help

up:  ## Start OTel Collector + Jaeger
	podman compose up -d
	@echo ""
	@echo "Jaeger UI:      http://localhost:16686"
	@echo "OTel Collector:  grpc://localhost:4317  http://localhost:4318"

down:  ## Stop everything
	podman compose down

logs:  ## Tail OTel collector logs
	podman compose logs -f otel-collector

jaeger:  ## Open Jaeger UI in browser
	@open http://localhost:16686 2>/dev/null || xdg-open http://localhost:16686 2>/dev/null || true

status:  ## Show running containers
	@podman compose ps

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
