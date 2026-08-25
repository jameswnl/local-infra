# Local Dev Infra

OTel Collector + Jaeger + OpenShell gateway, all running in Podman.

## Quick start

```bash
make up          # start everything
make register    # register gateway with CLI (one-time)
make jaeger      # open Jaeger UI
```

## Services

| Service          | Protocol | Address                 |
|------------------|----------|-------------------------|
| OpenShell gateway| gRPC     | `http://localhost:8080`  |
| Gateway health   | HTTP     | `http://localhost:8081`  |
| OTel Collector   | gRPC     | `grpc://localhost:4317`  |
| OTel Collector   | HTTP     | `http://localhost:4318`  |
| Jaeger UI        | HTTP     | `http://localhost:16686` |

## Using the gateway

```bash
# Create a sandbox
openshell sandbox create -- claude

# Check gateway health
make gateway-health
```

## Configuration

Gateway settings live in `gateway.toml`. The Podman compute driver is pre-configured.

The gateway container needs access to the Podman socket. The compose file defaults to `/run/user/501/podman/podman.sock`. Override with:

```bash
PODMAN_SOCK=/path/to/podman.sock make up
```

## Make targets

```
make up               Start everything (OTel + Jaeger + gateway)
make down             Stop everything
make logs             Tail OTel collector logs
make gateway-logs     Tail gateway logs
make gateway-health   Check gateway health
make jaeger           Open Jaeger UI in browser
make status           Show running containers
make register         Register gateway with the OpenShell CLI (one-time)
```

## OpenShift (OCP)

Deploys the real OpenShell Helm chart to an existing OpenShift project via `oc`
(assumes you're already logged in with `oc login`). Unlike the Kind path
above, sandboxes run through the [Agent Sandbox](https://agent-sandbox.sigs.k8s.io)
controller and the Kubernetes compute driver, not Podman DooD.

```bash
make ocp-openshell-up                    # install Agent Sandbox, grant SCC, helm install
make ocp-port-forward                    # foreground: localhost:8080 -> gateway
make ocp-register                        # register with the CLI (one-time, separate terminal)
make ocp-status                          # gateway + sandbox pods
make ocp-openshell-down                  # uninstall the release
```

Override the project name, chart version, or default sandbox image:

```bash
OCP_PROJECT=lcore OCP_CHART_VERSION=0.0.111 make ocp-openshell-up

# Use a custom sandbox image (e.g. one pushed to quay.io) instead of the
# chart default (ghcr.io/nvidia/openshell-community/sandboxes/base:latest):
OCP_PROJECT=lcore OCP_SANDBOX_IMAGE=quay.io/jameswong/lightspeed-agentic-sandbox:latest-amd64 make ocp-openshell-up
```

`OCP_SANDBOX_IMAGE` sets `server.sandboxImage`, the image used when
`openshell sandbox create` doesn't specify one. If the image lives in a
private registry, also set `server.sandboxImagePullSecrets` (not currently
plumbed through this Makefile — pass it via a second `-f`/`--set` on top of
`ocp-openshell-up`'s helm invocation, or make the repository public as this
setup does).

**Architecture matters.** `podman build` on Apple Silicon produces an arm64
image by default; OCP cluster nodes are typically amd64, and the sandbox
init container fails with `exec container process: Exec format error` if
the image doesn't match the node arch. Build and push with an explicit
platform:

```bash
podman build --platform linux/amd64 -f Containerfile -t quay.io/jameswong/<image>:latest-amd64 .
podman push quay.io/jameswong/<image>:latest-amd64
```

`ocp/values-eval.yaml` disables TLS and enables `allowUnauthenticatedUsers` —
this is the same tradeoff OpenShell's own eval docs make, and is only safe
behind `oc port-forward` on a private cluster. For a production install (real
cert, OpenShift Route, OIDC), follow `docs/kubernetes/openshift.mdx` in the
OpenShell repo instead of this values file.

`ocp/install-agent-sandbox.sh` installs the Agent Sandbox controller/CRDs,
a cluster-scoped dependency `ocp-openshell-down` intentionally leaves in
place (other projects on the cluster may depend on it). It resolves
whatever asset name the latest upstream release actually publishes, since
that release asset has been renamed before.

`make ocp-register` requires a CLI build recent enough to detect
`http://` + `--local` as a plaintext gateway rather than trying to pull
mTLS certs from a Docker container. If it fails with a Docker socket
error, build the CLI from the OpenShell repo (`cargo build -p
openshell-cli`) instead of using an older installed binary.

## OpenShift (OCP) — Production

Separate `ocp-prod-*` targets and variables from the eval ones above — own
project, own release name, own env vars — so both can be deployed to the
same or different clusters at once without clobbering each other. Follows
the "Production" path in `docs/kubernetes/openshift.mdx`: a real server
certificate via cert-manager, an OpenShift Route with TLS passthrough, and
OIDC for CLI auth (no `allowUnauthenticatedUsers` bypass).

One-time cluster setup (skip whichever piece you already have):

```bash
make ocp-prod-cert-manager-up            # installs cert-manager via OLM (Red Hat operator)

# If you don't have a real Issuer/ClusterIssuer yet (e.g. no ACME/corporate CA):
make ocp-prod-clusterissuer-selfsigned   # bootstraps a self-signed CA + ClusterIssuer

# If you don't have a real OIDC provider yet:
make ocp-prod-keycloak-up                # deploys a dev-grade Keycloak with a working realm
```

Then deploy (example values match the bootstrap self-signed issuer + dev Keycloak above):

```bash
make ocp-prod-check \
  OCP_PROD_HOSTNAME=openshell-prod.example.com \
  OCP_PROD_CLUSTER_ISSUER=openshell-selfsigned-ca \
  OCP_PROD_OIDC_ISSUER=http://keycloak.keycloak.svc.cluster.local:9090/realms/openshell

OCP_PROD_HOSTNAME=openshell-prod.example.com \
OCP_PROD_CLUSTER_ISSUER=openshell-selfsigned-ca \
OCP_PROD_OIDC_ISSUER=http://keycloak.keycloak.svc.cluster.local:9090/realms/openshell \
make ocp-prod-openshell-up

make ocp-prod-status
make ocp-prod-register   # openshell gateway add <hostname> --oidc-issuer ... + login
make ocp-prod-openshell-down
```

I've run this exact sequence end-to-end against a real OCP cluster (self-signed
issuer + dev Keycloak): the gateway comes up with `TLS enabled`, `OIDC
authentication enabled`, successfully discovers Keycloak's JWKS, and its
logged discovered issuer matches token `iss` claims exactly. What I didn't
verify is a literal `openshell gateway login` browser round-trip, since that
needs a real, browser-reachable hostname (see the two notes below for why
`openshell-prod.example.com` alone isn't enough).

`OCP_PROD_HOSTNAME`, `OCP_PROD_CLUSTER_ISSUER`, and `OCP_PROD_OIDC_ISSUER`
have no defaults — `ocp-prod-check` (which `ocp-prod-openshell-up` always
runs first) fails with a clear message if any are missing, if `oc` isn't
logged in, if cert-manager isn't installed, or if the named ClusterIssuer
isn't `Ready`. Other overridable variables: `OCP_PROD_PROJECT` (default
`openshell-prod`), `OCP_PROD_RELEASE` (default `openshell-prod` — must
differ from the eval path's `openshell`; see note below),
`OCP_PROD_OIDC_AUDIENCE` (default `openshell-cli`), `OCP_PROD_SANDBOX_IMAGE`.

Notes:
- `ocp-prod-cert-manager-up` installs Red Hat's official cert-manager
  Operator via OLM (`redhat-operators` catalog, `stable-v1` channel) —
  cluster-scoped and shared, so `ocp-prod-openshell-down` intentionally
  leaves it in place.
- `ocp-prod-clusterissuer-selfsigned` is a bootstrap convenience, not a
  substitute for a real ACME/corporate issuer: the resulting cert is not
  publicly trusted, so CLI clients need the CA cert to verify the
  connection (or `--gateway-insecure`). Swap in a real
  `Issuer`/`ClusterIssuer` and point `OCP_PROD_CLUSTER_ISSUER` at it once
  you have one.
- `ocp-prod-keycloak-up` deploys Keycloak into its own `keycloak` namespace
  (not `OCP_PROD_PROJECT`) with an in-memory DB — state (including the
  imported realm) is lost on pod restart, but `--import-realm` re-imports
  it automatically. Test users: `admin@test` / `admin` (role
  `openshell-admin`) and `user@test` / `user` (role `openshell-user`),
  client `openshell-cli` (public, Authorization Code + PKCE and direct
  access grants both enabled).
- **Keycloak's `iss` claim always reflects the actual port a request
  arrived on**, regardless of `KC_HOSTNAME_STRICT`/`KC_HOSTNAME_PORT`
  settings (verified empirically against Keycloak 24, contradicting what
  those settings are documented to do). So the dev Keycloak Service
  listens on port 9090 (not the HTTP default 80) — the same port used for
  `kubectl port-forward` — so tokens obtained via a local port-forward and
  tokens validated by the in-cluster gateway carry an identical `iss`. If
  you change `KEYCLOAK_SETUP_PORT`, re-verify token issuers still match
  before trusting the deployment.
- The chart creates a cluster-scoped `ClusterRole`/`ClusterRoleBinding`
  named after the Helm release (`<release>-node-reader`, etc.). Two
  releases with the same name anywhere on the cluster collide even in
  different namespaces — this is why `OCP_PROD_RELEASE` defaults to
  `openshell-prod` rather than reusing the eval path's `openshell`.
- Registering the CLI against a self-signed cert + a hostname that isn't
  real DNS (like the `openshell-prod.example.com` example above) won't
  work as-is: `openshell gateway add` needs to actually reach the
  hostname and trust its certificate. For a real deployment, point
  `OCP_PROD_HOSTNAME` at a real, resolvable domain; for local proof-of-concept
  registration against the example above, add a `/etc/hosts` entry
  pointing it at a `oc port-forward`'d local address and use
  `openshell gateway add --gateway-insecure` to skip cert trust.
- Same sandbox-image architecture caveat as the eval path applies here —
  see below.

## Architecture

```
openshell CLI ──▶ gateway (:8080, Podman driver)
                    ├──▶ sandbox containers (via Podman socket)
                    └──▶ OTel Collector (:4317)
                           ├──▶ Jaeger (:16686)
                           └──▶ debug (stdout)
```
