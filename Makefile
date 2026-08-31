# Local dev infra — OTel + Jaeger + OpenShell
#
# Podman compose targets manage the local container stack.
# Kind targets manage a Kubernetes cluster with services deployed as pods.
# The canonical Kind OpenShell path (`kind-openshell-up`) uses the real
# Helm chart + Agent Sandbox controller (Kubernetes compute driver) --
# matching the architecture rule that all K8s/OCP/Kind deployments use the
# kubernetes driver, Podman deployments use the podman driver, no other
# combination. The old Podman-DooD Kind path is kept as `kind-openshell-
# podman-up` for reference/comparison, not as a supported deployment target.
# OCP targets deploy the real OpenShell Helm chart to an existing OpenShift
# project via `oc` (assumes you're already logged in).

KIND_CLUSTER          ?= local-infra
KIND_KUBECONFIG       ?= $(CURDIR)/kind/kubeconfig
KUBECTL               := kubectl --kubeconfig $(KIND_KUBECONFIG)
KIND_CHART_VERSION    ?= 0.0.111
KIND_OPENSHELL_NS     ?= openshell-k8s
KIND_OPENSHELL_PORT   ?= 9090
KIND_GATEWAY_NAME     ?= local-kind

# Source repos for images built by the *-lightspeed-* and *-sandbox-build
# targets below. Each build verifies its repo is on a clean, up-to-date
# origin/main checkout (scripts/check-clean-main.sh) before building, so
# these targets never silently bake in stale or uncommitted source.
LIGHTSPEED_STACK_REPO         ?= $(HOME)/ws/lightspeed-stack
LIGHTSPEED_CLOUD_AGENTS_REPO  ?= $(HOME)/ws/lightspeed-cloud-agents
LIGHTSPEED_SANDBOX_REPO       ?= $(HOME)/ws/lightspeed-agentic-sandbox
LIGHTSPEED_STACK_IMAGE_REPO   ?= quay.io/jameswong/lightspeed-stack
LIGHTSPEED_SANDBOX_IMAGE_REPO ?= quay.io/jameswong/lightspeed-agentic-sandbox

OCP_PROJECT       ?= openshell
OCP_CHART_VERSION ?= 0.0.111
OCP_GATEWAY_NAME  ?= ocp
OCP_SANDBOX_IMAGE ?=

# Production OpenShift install — separate project/release/variables from the
# eval ones above so both can target the same or different clusters without
# clobbering each other. No safe defaults for hostname/issuer/OIDC: they are
# cluster-specific and required (see ocp-prod-check).
OCP_PROD_PROJECT       ?= openshell-prod
# Must differ from OCP_PROJECT's implied "openshell" release name: the chart
# creates a cluster-scoped ClusterRole/ClusterRoleBinding named after the
# release, which collides across namespaces if two releases share a name.
OCP_PROD_RELEASE       ?= openshell-prod
OCP_PROD_CHART_VERSION ?= 0.0.111
OCP_PROD_GATEWAY_NAME  ?= ocp-prod
OCP_PROD_SANDBOX_IMAGE ?=
OCP_PROD_HOSTNAME      ?=
OCP_PROD_CLUSTER_ISSUER ?=
OCP_PROD_ISSUER_KIND   ?= ClusterIssuer
OCP_PROD_OIDC_ISSUER   ?=
OCP_PROD_OIDC_AUDIENCE ?= openshell-cli
OCP_PROD_SELFSIGNED_ISSUER_NAME ?= openshell-selfsigned-ca
OCP_PROD_SELFSIGNED_CA_SECRET   ?= openshell-selfsigned-ca-tls

export KIND_EXPERIMENTAL_PROVIDER=podman

.PHONY: up down logs logs-otel logs-openshell openshell-health jaeger status register help \
        up-openshell down-openshell \
        kind-up kind-down kind-status kind-agent-sandbox-up \
        kind-openshell-up kind-openshell-down kind-openshell-logs \
        kind-openshell-port-forward kind-openshell-register kind-openshell-test-spawn \
        kind-openshell-podman-up kind-openshell-podman-down kind-openshell-podman-logs \
        kind-openshell-podman-health kind-openshell-podman-register \
        kind-lightspeed-build kind-lightspeed-apply kind-lightspeed-up \
        ocp-eval-up ocp-eval-status ocp-eval-agent-sandbox-up \
        ocp-eval-openshell-up ocp-eval-openshell-down ocp-eval-openshell-logs \
        ocp-eval-port-forward ocp-eval-register ocp-eval-test-eacces-repro \
        ocp-sandbox-build \
        ocp-prod-check ocp-prod-up ocp-prod-status ocp-prod-agent-sandbox-up \
        ocp-prod-cert-manager-up ocp-prod-clusterissuer-selfsigned ocp-prod-keycloak-up \
        ocp-prod-openshell-up ocp-prod-openshell-down ocp-prod-openshell-logs \
        ocp-prod-lightspeed-build ocp-prod-lightspeed-apply ocp-prod-lightspeed-up \
        ocp-prod-register ocp-prod-quickstart ocp-prod-test-eacces-repro

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

kind-status:  ## Show Kind clusters, plus all pods + sandboxes in KIND_CLUSTER
	@echo "Kind clusters:"
	@kind get clusters 2>/dev/null | sed 's/^/  /'
	@echo ""
	@echo "Pods + sandboxes in '$(KIND_CLUSTER)':"
	@$(KUBECTL) get pods -A
	@$(KUBECTL) get sandboxes.agents.x-k8s.io -A 2>/dev/null || true

kind-agent-sandbox-up:  ## Install the Agent Sandbox controller/CRDs into Kind (cluster-scoped, idempotent)
	KUBECONFIG=$(KIND_KUBECONFIG) ./ocp/install-agent-sandbox.sh

# ---------- Kind: OpenShell (canonical -- Kubernetes compute driver) ----------
#
# Deploys the real OpenShell Helm chart (not raw manifests), same as the OCP
# eval path below, with TLS/auth disabled for local testing. Sandbox pods run
# via the Agent Sandbox controller, exactly like OCP/production -- this is
# what makes it a meaningful local stand-in for the real deployment target,
# unlike the Podman-DooD legacy path (kind-openshell-podman-up).
#
# Deliberately does NOT reuse ocp/values-eval.yaml wholesale: that file also
# nulls podSecurityContext.fsGroup/securityContext.runAsUser, which is an
# OpenShift-SCC-specific workaround. On plain Kubernetes (Kind), nulling
# those breaks the gateway's own JWT-signing-key Secret mount (mode 0400) --
# the chart's own fsGroup:1000/runAsUser:1000 defaults are what make it
# group-readable, so Kind must keep them.

kind-openshell-up: kind-up kind-agent-sandbox-up  ## Deploy OpenShell to Kind (kubernetes driver, canonical)
	@echo "[kind] Deploying OpenShell (kubernetes driver)..."
	@$(KUBECTL) create namespace $(KIND_OPENSHELL_NS) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	helm upgrade --install openshell-k8s oci://ghcr.io/nvidia/openshell/helm-chart \
		--version $(KIND_CHART_VERSION) \
		--namespace $(KIND_OPENSHELL_NS) \
		-f kind/values-k8s-driver.yaml \
		--kubeconfig $(KIND_KUBECONFIG)
	@$(KUBECTL) -n $(KIND_OPENSHELL_NS) rollout status statefulset/openshell-k8s --timeout=180s
	@echo ""
	@echo "Forward the gateway:  make kind-openshell-port-forward"
	@echo "Register (one-time):  make kind-openshell-register"
	@echo "Test a real spawn:    make kind-openshell-test-spawn"

kind-openshell-down:  ## Uninstall OpenShell from Kind
	helm uninstall openshell-k8s -n $(KIND_OPENSHELL_NS) --kubeconfig $(KIND_KUBECONFIG) --ignore-not-found

kind-openshell-logs:  ## Tail OpenShell gateway logs in Kind
	$(KUBECTL) -n $(KIND_OPENSHELL_NS) logs -f statefulset/openshell-k8s

kind-openshell-port-forward:  ## Port-forward the Kind OpenShell gateway to localhost (foreground)
	$(KUBECTL) -n $(KIND_OPENSHELL_NS) port-forward svc/openshell-k8s $(KIND_OPENSHELL_PORT):8080

kind-openshell-register:  ## Register the Kind OpenShell gateway with the CLI (one-time; requires port-forward running)
	# No --local: that flag extracts mTLS certs from a Docker container, but
	# kind/values-k8s-driver.yaml runs with disableTls/allowUnauthenticatedUsers,
	# and the gateway is a K8s pod, not a host Docker container.
	openshell gateway add http://127.0.0.1:$(KIND_OPENSHELL_PORT) --name $(KIND_GATEWAY_NAME)

kind-openshell-test-spawn:  ## Run a real spawn test via the kubernetes driver (requires cloud_agents + openshell installed)
	@$(KUBECTL) -n $(KIND_OPENSHELL_NS) port-forward svc/openshell-k8s $(KIND_OPENSHELL_PORT):8080 \
		>/tmp/kind-openshell-port-forward.log 2>&1 & \
	PF_PID=$$!; \
	sleep 2; \
	OPENSHELL_GATEWAY_URL=localhost:$(KIND_OPENSHELL_PORT) python3 kind/test-k8s-driver-spawn.py; \
	STATUS=$$?; \
	kill $$PF_PID 2>/dev/null; \
	exit $$STATUS

# ---------- Kind: OpenShell (legacy -- Podman DooD) ----------
#
# Reference/comparison path only: sandboxes run via the Podman compute
# driver against the host's Podman socket mounted into the Kind node
# (Docker-out-of-Docker style). Not a supported deployment target under the
# OpenShellSpawner-only architecture (Kind counts as a Kubernetes target,
# which uses the kubernetes driver exclusively) -- kept for debugging/
# comparison against kind-openshell-up above.

kind-openshell-podman-up: kind-up  ## Deploy OpenShell to Kind via Podman DooD (legacy, not a supported target)
	@echo "[kind] Deploying OpenShell (podman driver, legacy)..."
	@$(KUBECTL) apply -f kind/openshell-gateway.yaml
	@$(KUBECTL) -n openshell rollout status deployment/openshell-gateway --timeout=120s
	@echo ""
	@echo "OpenShell: http://localhost:9080"
	@echo "Health:    http://localhost:9081/healthz"
	@echo ""
	@echo "Register (one-time):  make kind-openshell-podman-register"

kind-openshell-podman-down:  ## Remove the legacy Podman-DooD OpenShell deployment from Kind
	$(KUBECTL) delete -f kind/openshell-gateway.yaml --ignore-not-found

kind-openshell-podman-logs:  ## Tail logs for the legacy Podman-DooD OpenShell deployment
	$(KUBECTL) -n openshell logs -f deployment/openshell-gateway

kind-openshell-podman-health:  ## Check health of the legacy Podman-DooD OpenShell deployment
	@curl -sf http://localhost:9081/healthz && echo " OK" || echo " UNHEALTHY"

kind-openshell-podman-register:  ## Register the legacy Podman-DooD Kind OpenShell gateway with the CLI (one-time)
	openshell gateway add http://localhost:9080 --name local-kind-podman

# ---------- Kind: lightspeed-stack ----------
#
# Deploys lightspeed-stack + Postgres into the same namespace as the
# canonical Kind OpenShell gateway (kind/lightspeed-stack.yaml), wired via
# in-cluster Service DNS. Requires the harness-only image (not the official
# product image, which has no cloud_agents dependency) -- kind-lightspeed-
# build builds it from clean origin/main checkouts of lightspeed-stack and
# lightspeed-cloud-agents and loads it into the Kind node so the freshness
# guarantee actually holds (imagePullPolicy: Never means the manifest's
# fixed "kind-test-harness" tag only ever reflects what was last loaded).
#
# Requires a one-time secret before the pod will actually start:
#   kubectl --kubeconfig kind/kubeconfig -n openshell-k8s create secret \
#     generic lightspeed-stack-llm-secret --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY"

kind-lightspeed-build:  ## Build the lightspeed-stack harness image from clean main (stack + cloud_agents) and load it into Kind
	@STACK_REPO=$(LIGHTSPEED_STACK_REPO) \
	 AGENTS_REPO=$(LIGHTSPEED_CLOUD_AGENTS_REPO) \
	 IMAGE_REPO=localhost/lightspeed-stack \
	 ALIAS_TAG=kind-test-harness \
	 PLATFORM=linux/arm64 \
	 PUSH=false \
	 KIND_CLUSTER=$(KIND_CLUSTER) \
	 ./scripts/build-lightspeed-stack.sh

kind-lightspeed-apply: kind-openshell-up  ## Apply lightspeed-stack to Kind, restarting it if already running (requires kind-lightspeed-build first)
	@$(KUBECTL) apply -f kind/lightspeed-stack.yaml
	@$(KUBECTL) -n $(KIND_OPENSHELL_NS) rollout restart deployment/lightspeed-stack 2>/dev/null || true
	@$(KUBECTL) -n $(KIND_OPENSHELL_NS) rollout status deployment/lightspeed-stack --timeout=180s

kind-lightspeed-up: kind-lightspeed-build kind-lightspeed-apply  ## Build lightspeed-stack from clean main and (re)deploy it to Kind alongside the gateway

# ---------- OpenShift (oc) ----------
#
# Deploys the real OpenShell Helm chart (not raw manifests) using the
# documented OpenShift eval path: SCC binding + TLS/auth disabled overrides
# in ocp/values-eval.yaml. Requires an existing `oc login` session.
# Sandbox pods run via the Agent Sandbox controller (Kubernetes compute
# driver) -- same driver as the canonical kind-openshell-up path above,
# just with OpenShift-specific SCC handling instead of Kind's plain fsGroup/
# runAsUser defaults.

ocp-eval-up:  ## Create the OpenShift project if it doesn't already exist
	@oc get project $(OCP_PROJECT) >/dev/null 2>&1 || oc new-project $(OCP_PROJECT)

ocp-eval-status:  ## Show all pods + sandboxes in the OpenShift project
	@oc -n $(OCP_PROJECT) get pods
	@oc -n $(OCP_PROJECT) get sandboxes.agents.x-k8s.io 2>/dev/null || true

ocp-eval-agent-sandbox-up:  ## Install the Agent Sandbox controller/CRDs (cluster-scoped, idempotent)
	./ocp/install-agent-sandbox.sh

ocp-eval-openshell-up: ocp-eval-up ocp-eval-agent-sandbox-up  ## Deploy OpenShell to OpenShift (eval: TLS + auth disabled)
	oc adm policy add-scc-to-user privileged -z openshell-sandbox -n $(OCP_PROJECT)
	helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
		--version $(OCP_CHART_VERSION) \
		--namespace $(OCP_PROJECT) \
		-f ocp/values-eval.yaml \
		$(if $(OCP_SANDBOX_IMAGE),--set server.sandboxImage=$(OCP_SANDBOX_IMAGE),)
	oc -n $(OCP_PROJECT) rollout status statefulset/openshell --timeout=180s
	@echo ""
	@echo "Forward the gateway:  make ocp-eval-port-forward"
	@echo "Register (one-time):  make ocp-eval-register"

ocp-eval-openshell-down:  ## Uninstall the OpenShell release from OpenShift
	helm uninstall openshell -n $(OCP_PROJECT) --ignore-not-found

ocp-eval-openshell-logs:  ## Tail OpenShell gateway logs on OpenShift
	oc -n $(OCP_PROJECT) logs -f statefulset/openshell

ocp-eval-port-forward:  ## Port-forward the OpenShift gateway to localhost:8080 (foreground)
	oc -n $(OCP_PROJECT) port-forward svc/openshell 8080:8080

ocp-eval-register:  ## Register the OpenShift gateway with the OpenShell CLI (one-time)
	# No --local: that flag extracts mTLS certs from a Docker container, but
	# ocp/values-eval.yaml runs with disableTls/allowUnauthenticatedUsers, and
	# the gateway is an OpenShift pod, not a host Docker container.
	openshell gateway add http://127.0.0.1:8080 --name $(OCP_GATEWAY_NAME)

ocp-eval-test-eacces-repro:  ## Test for the OCP kubernetes-driver EACCES-on-later-layer-content bug (requires ocp-eval-register first)
	./ocp/test-eacces-repro.sh $(OCP_GATEWAY_NAME) $(OCP_PROJECT) $(OCP_SANDBOX_IMAGE)

# ---------- Sandbox image ----------
#
# Builds the agentic sandbox image used by both ocp-eval-openshell-up
# (OCP_SANDBOX_IMAGE) and ocp-prod-openshell-up (OCP_PROD_SANDBOX_IMAGE)
# from a clean origin/main checkout of lightspeed-agentic-sandbox. Prints
# the immutable <image>:<sha> ref to use with either variable -- pass it
# explicitly rather than relying on the mutable "latest-amd64" alias tag,
# since that's also pushed but Kubernetes may not re-pull an unchanged tag.

ocp-sandbox-build:  ## Build the agentic sandbox image from clean main and push it (use the printed <image>:<sha> ref as OCP_SANDBOX_IMAGE / OCP_PROD_SANDBOX_IMAGE)
	@SANDBOX_REPO=$(LIGHTSPEED_SANDBOX_REPO) \
	 IMAGE_REPO=$(LIGHTSPEED_SANDBOX_IMAGE_REPO) \
	 ALIAS_TAG=latest-amd64 \
	 PLATFORM=linux/amd64 \
	 ./scripts/build-sandbox.sh

# ---------- OpenShift (oc) — Production ----------
#
# Real server certificate (cert-manager) + OpenShift Route (TLS passthrough)
# + OIDC CLI auth — the "Production" path in docs/kubernetes/openshift.mdx
# in the OpenShell repo. Kept as separate ocp-prod-* targets/variables from
# the eval ocp-* targets above: different project, release name, and Make
# variables, so both can run against the same or different clusters at once.
#
# Prerequisites this repo does not install: cert-manager with a working
# Issuer/ClusterIssuer, and an OIDC provider. ocp-prod-check verifies both
# plus the required variables below before ocp-prod-openshell-up proceeds.
#
# Required variables (no safe defaults):
#   OCP_PROD_HOSTNAME        external hostname for the Route + server cert
#   OCP_PROD_CLUSTER_ISSUER  name of an existing, Ready cert-manager ClusterIssuer
#   OCP_PROD_OIDC_ISSUER     OIDC issuer URL the gateway validates tokens against

ocp-prod-check:  ## Verify production prerequisites (cert-manager, ClusterIssuer, required vars)
	./ocp/check-prod-prereqs.sh "$(OCP_PROD_HOSTNAME)" "$(OCP_PROD_CLUSTER_ISSUER)" "$(OCP_PROD_OIDC_ISSUER)"

ocp-prod-up:  ## Create the production OpenShift project if it doesn't already exist
	@oc get project $(OCP_PROD_PROJECT) >/dev/null 2>&1 || oc new-project $(OCP_PROD_PROJECT)

ocp-prod-status:  ## Show pods + sandboxes + Route in the production project
	@oc -n $(OCP_PROD_PROJECT) get pods
	@oc -n $(OCP_PROD_PROJECT) get sandboxes.agents.x-k8s.io 2>/dev/null || true
	@oc -n $(OCP_PROD_PROJECT) get route $(OCP_PROD_RELEASE) 2>/dev/null || true

ocp-prod-agent-sandbox-up:  ## Install the Agent Sandbox controller/CRDs (cluster-scoped, idempotent)
	./ocp/install-agent-sandbox.sh

ocp-prod-cert-manager-up:  ## Install cert-manager via OLM (Red Hat operator, cluster-scoped, idempotent)
	./ocp/install-cert-manager-operator.sh

ocp-prod-clusterissuer-selfsigned:  ## Bootstrap a self-signed CA + ClusterIssuer (use when you don't have a real one yet)
	./ocp/install-selfsigned-clusterissuer.sh "$(OCP_PROD_SELFSIGNED_ISSUER_NAME)" "$(OCP_PROD_SELFSIGNED_CA_SECRET)"
	@echo ""
	@echo "ClusterIssuer ready: $(OCP_PROD_SELFSIGNED_ISSUER_NAME)"
	@echo "Use it with:  OCP_PROD_CLUSTER_ISSUER=$(OCP_PROD_SELFSIGNED_ISSUER_NAME) make ocp-prod-openshell-up"

ocp-prod-keycloak-up:  ## Deploy a dev-grade Keycloak (not persistent) for testing the OIDC production path
	./ocp/install-dev-keycloak.sh

ocp-prod-openshell-up: ocp-prod-check ocp-prod-up ocp-prod-agent-sandbox-up  ## Deploy OpenShell to OpenShift (production: real TLS + OIDC)
	# SA name follows Helm's <release-name>-sandbox convention, not a fixed
	# "openshell-sandbox" -- the eval target's hardcoded release name
	# ("openshell") happens to match its own hardcoded SCC grant below, but
	# OCP_PROD_RELEASE defaults to "openshell-prod", so this must track it.
	oc adm policy add-scc-to-user privileged -z $(OCP_PROD_RELEASE)-sandbox -n $(OCP_PROD_PROJECT)
	# certManager.serverDnsNames[0] drives the certificate's commonName, which
	# X.509 caps at 64 bytes (RFC 5280) -- managed OpenShift's auto-generated
	# apps domains are frequently already 50+ bytes, so a real hostname often
	# doesn't fit. [0] is a short synthetic label used only for commonName;
	# the real hostname goes in [1] as a SAN, which is what TLS clients
	# actually validate against (RFC 6125) and is also what satisfies
	# route.yaml's host-coverage check (it scans all serverDnsNames entries).
	helm upgrade --install $(OCP_PROD_RELEASE) oci://ghcr.io/nvidia/openshell/helm-chart \
		--version $(OCP_PROD_CHART_VERSION) \
		--namespace $(OCP_PROD_PROJECT) \
		-f ocp/values-prod.yaml \
		--set certManager.serverIssuerRef.name=$(OCP_PROD_CLUSTER_ISSUER) \
		--set certManager.serverIssuerRef.kind=$(OCP_PROD_ISSUER_KIND) \
		--set certManager.serverDnsNames[0]=$(OCP_PROD_RELEASE)-external \
		--set certManager.serverDnsNames[1]=$(OCP_PROD_HOSTNAME) \
		--set openshiftRoute.enabled=true \
		--set openshiftRoute.host=$(OCP_PROD_HOSTNAME) \
		--set server.oidc.issuer=$(OCP_PROD_OIDC_ISSUER) \
		--set server.oidc.audience=$(OCP_PROD_OIDC_AUDIENCE) \
		$(if $(OCP_PROD_SANDBOX_IMAGE),--set server.sandboxImage=$(OCP_PROD_SANDBOX_IMAGE),)
	oc -n $(OCP_PROD_PROJECT) rollout status statefulset/$(OCP_PROD_RELEASE) --timeout=180s
	@echo ""
	@echo "Gateway:              https://$(OCP_PROD_HOSTNAME)"
	@echo "Register (one-time):  make ocp-prod-register"

ocp-prod-openshell-down:  ## Uninstall the production OpenShell release
	helm uninstall $(OCP_PROD_RELEASE) -n $(OCP_PROD_PROJECT) --ignore-not-found

ocp-prod-openshell-logs:  ## Tail OpenShell gateway logs in production
	oc -n $(OCP_PROD_PROJECT) logs -f statefulset/$(OCP_PROD_RELEASE)

# ---------- OpenShift (oc) — Production: lightspeed-stack ----------
#
# Deploys lightspeed-stack + Postgres into the production project, wired to
# the gateway via in-cluster Service DNS (see ocp/lightspeed-stack.yaml's
# header for the required secrets and OIDC token refresh steps -- not
# automated here). ocp-prod-lightspeed-build builds the harness image from
# clean origin/main checkouts of lightspeed-stack and lightspeed-cloud-
# agents and pushes it under the fixed "ocp-harness" tag the manifest
# references; the manifest sets imagePullPolicy: Always specifically so
# that a same-tag push is guaranteed to be re-pulled on rollout restart.

ocp-prod-lightspeed-build:  ## Build the lightspeed-stack harness image from clean main (stack + cloud_agents) and push it
	@STACK_REPO=$(LIGHTSPEED_STACK_REPO) \
	 AGENTS_REPO=$(LIGHTSPEED_CLOUD_AGENTS_REPO) \
	 IMAGE_REPO=$(LIGHTSPEED_STACK_IMAGE_REPO) \
	 ALIAS_TAG=ocp-harness \
	 PLATFORM=linux/amd64 \
	 PUSH=true \
	 ./scripts/build-lightspeed-stack.sh

ocp-prod-lightspeed-apply:  ## Apply lightspeed-stack to the production project, restarting it if already running (requires ocp-prod-lightspeed-build first)
	@oc -n $(OCP_PROD_PROJECT) apply -f ocp/lightspeed-stack.yaml
	@oc -n $(OCP_PROD_PROJECT) rollout restart deployment/lightspeed-stack 2>/dev/null || true
	@oc -n $(OCP_PROD_PROJECT) rollout status deployment/lightspeed-stack --timeout=180s

ocp-prod-lightspeed-up: ocp-prod-lightspeed-build ocp-prod-lightspeed-apply  ## Build lightspeed-stack from clean main and (re)deploy it to production OpenShift

ocp-prod-register:  ## Register the production gateway with the OpenShell CLI over OIDC
	openshell gateway add https://$(OCP_PROD_HOSTNAME) --name $(OCP_PROD_GATEWAY_NAME) --oidc-issuer $(OCP_PROD_OIDC_ISSUER)
	openshell gateway login $(OCP_PROD_GATEWAY_NAME)

ocp-prod-test-eacces-repro:  ## Test for the OCP kubernetes-driver EACCES-on-later-layer-content bug (requires ocp-prod-register first)
	./ocp/test-eacces-repro.sh $(OCP_PROD_GATEWAY_NAME) $(OCP_PROD_PROJECT) $(OCP_PROD_SANDBOX_IMAGE)

ocp-prod-quickstart: ocp-prod-cert-manager-up ocp-prod-clusterissuer-selfsigned ocp-prod-keycloak-up  ## One-shot prod deploy on a brand-new cluster: bootstraps self-signed CA + dev Keycloak, computes a hostname, deploys, and registers
	@host="$(OCP_PROD_HOSTNAME)"; \
	if [ -z "$$host" ]; then \
		domain=$$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null); \
		if [ -z "$$domain" ]; then \
			echo "error: could not read the cluster's default Ingress domain (ingresses.config.openshift.io/cluster)." >&2; \
			echo "Set OCP_PROD_HOSTNAME explicitly instead, e.g.:" >&2; \
			echo "  OCP_PROD_HOSTNAME=openshell.apps.mycluster.example.com make ocp-prod-quickstart" >&2; \
			exit 1; \
		fi; \
		host="$(OCP_PROD_RELEASE)-$(OCP_PROD_PROJECT).$$domain"; \
		echo "OCP_PROD_HOSTNAME not set -- using cluster default: $$host"; \
	fi; \
	issuer="$(OCP_PROD_OIDC_ISSUER)"; \
	if [ -z "$$issuer" ]; then \
		issuer="http://keycloak.keycloak.svc.cluster.local:9090/realms/openshell"; \
	fi; \
	$(MAKE) ocp-prod-openshell-up \
		OCP_PROD_HOSTNAME="$$host" \
		OCP_PROD_CLUSTER_ISSUER="$(OCP_PROD_SELFSIGNED_ISSUER_NAME)" \
		OCP_PROD_OIDC_ISSUER="$$issuer"; \
	$(MAKE) ocp-prod-register \
		OCP_PROD_HOSTNAME="$$host" \
		OCP_PROD_OIDC_ISSUER="$$issuer"

# ---------- Help ----------

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
