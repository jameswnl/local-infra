# Local Dev Infra

OTel Collector + Jaeger + OpenShell gateway. Four ways to run the gateway,
from a local Podman stack up to a production-shaped OpenShift deployment.

## Which environment?

| Environment | What it's for | Sandboxes run via | Get started |
|---|---|---|---|
| [Podman](#podman) | Fastest local loop | Podman socket (DooD) | `make up` |
| [Kind](#kind-local-kubernetes) | Testing the Kubernetes compute driver locally | Agent Sandbox controller | `make kind-up` |
| [OpenShift — Eval](#openshift--eval) | Quick test against a real OCP cluster | Agent Sandbox controller | `make ocp-eval-openshell-up` |
| [OpenShift — Production](#openshift--production) | Real TLS + OIDC on OCP | Agent Sandbox controller | `make ocp-prod-openshell-up` |

Run `make help` for the full target list at any time.

## Podman

```bash
make up          # start everything (OTel + Jaeger + gateway)
make register    # register gateway with CLI (one-time)
make jaeger      # open Jaeger UI
```

### Services

| Service          | Protocol | Address                 |
|------------------|----------|-------------------------|
| OpenShell gateway| gRPC     | `http://localhost:8080`  |
| Gateway health   | HTTP     | `http://localhost:8081`  |
| OTel Collector   | gRPC     | `grpc://localhost:4317`  |
| OTel Collector   | HTTP     | `http://localhost:4318`  |
| Jaeger UI        | HTTP     | `http://localhost:16686` |

### Using the gateway

```bash
openshell sandbox create -- claude   # create a sandbox
make gateway-health                  # check gateway health
```

### Configuration

Gateway settings live in `gateway.toml`. The Podman compute driver is pre-configured.

The gateway container needs access to the Podman socket. The compose file defaults to `/run/user/501/podman/podman.sock`. Override with:

```bash
PODMAN_SOCK=/path/to/podman.sock make up
```

### Make targets

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

### Architecture

```
openshell CLI ──▶ gateway (:8080, Podman driver)
                    ├──▶ sandbox containers (via Podman socket)
                    └──▶ OTel Collector (:4317)
                           ├──▶ Jaeger (:16686)
                           └──▶ debug (stdout)
```

## Kind (local Kubernetes)

A local Kind cluster with the real OpenShell Helm chart deployed, same as
the OpenShift paths below. Sandboxes run via the Agent Sandbox controller
(Kubernetes compute driver) — this is the canonical local stand-in for a
real K8s/OCP deployment, not just a Kubernetes-deployment-mechanics
smoke test.

```bash
make kind-up                      # create the Kind cluster
make kind-openshell-up            # install the Agent Sandbox CRD/controller + deploy the gateway
make kind-openshell-register      # register with the CLI (one-time; needs port-forward running)
make kind-openshell-port-forward  # forward the gateway to localhost:9090 (foreground)
make kind-openshell-test-spawn    # real spawn test via the kubernetes driver (needs cloud_agents + openshell installed)
make kind-status                  # all pods + sandboxes in the cluster
make kind-down                    # delete the cluster
```

Gateway: `http://127.0.0.1:9090` (once `kind-openshell-port-forward` is running).

### Legacy: Podman DooD on Kind

An older path (`make kind-openshell-podman-up`) deploys the gateway as a
plain Deployment (raw manifests) with sandboxes running via Podman DooD —
the host's Podman socket mounted into the Kind node — instead of the Agent
Sandbox controller. Kept for reference/comparison only; not a supported
deployment target (Kind counts as a Kubernetes target, which uses the
kubernetes compute driver exclusively). See
`make kind-openshell-podman-up/-down/-logs/-health/-register`.

Gateway: `http://localhost:9080` · Health: `http://localhost:9081/healthz`

## OpenShift — Eval

Deploys the real OpenShell Helm chart to an existing OpenShift project via
`oc` (assumes you're already logged in with `oc login`). Unlike Kind above,
sandboxes run through the [Agent Sandbox](https://agent-sandbox.sigs.k8s.io)
controller and the Kubernetes compute driver, not Podman DooD.

TLS and CLI auth are both disabled (`ocp/values-eval.yaml`) — the same
tradeoff OpenShell's own eval docs make. Only safe behind `oc port-forward`
on a private cluster; never expose this externally. For a real deployment,
see [OpenShift — Production](#openshift--production).

```bash
make ocp-eval-openshell-up      # install Agent Sandbox, grant SCC, helm install
make ocp-eval-port-forward      # foreground: localhost:8080 -> gateway
make ocp-eval-register          # register with the CLI (one-time, separate terminal)
make ocp-eval-status            # gateway + sandbox pods
make ocp-eval-openshell-down    # uninstall the release
```

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `OCP_PROJECT` | `openshell` | OpenShift project (namespace) |
| `OCP_CHART_VERSION` | `0.0.111` | OpenShell Helm chart version |
| `OCP_GATEWAY_NAME` | `ocp` | Name used when registering with the CLI |
| `OCP_SANDBOX_IMAGE` | *(chart default)* | Default sandbox image — see below |

```bash
OCP_PROJECT=lcore OCP_CHART_VERSION=0.0.111 make ocp-eval-openshell-up

# Use a custom sandbox image (e.g. one pushed to quay.io) instead of the
# chart default (ghcr.io/nvidia/openshell-community/sandboxes/base:latest):
OCP_PROJECT=lcore OCP_SANDBOX_IMAGE=quay.io/jameswong/lightspeed-agentic-sandbox:latest-amd64 make ocp-eval-openshell-up
```

`OCP_SANDBOX_IMAGE` sets `server.sandboxImage`. If the image lives in a
private registry, also set `server.sandboxImagePullSecrets` (not currently
plumbed through this Makefile — pass it via a second `-f`/`--set` on top of
`ocp-eval-openshell-up`'s helm invocation, or make the repository public as
this setup does).

### Diagnostics

```bash
make ocp-eval-test-eacces-repro   # requires ocp-eval-register first
```

Tests for a real, unresolved OCP `kubernetes`-driver bug — see
`~/ws/lightspeed-stack/docs/design/cloud-agents/prod/ocp-sandbox-file-read-eacces.md`:
on some OCP clusters, any file added to a sandbox image in a layer *after*
its base image returns `EACCES` on read, even though permissions/ownership
look completely normal. Checking existence or the executable bit (`command
-v`, `which`) does **not** exercise this — it needs an actual `open()` and
an actual execution. The script does both: reads a base-image file
(control), reads a file `COPY`'d in a later layer (repro), and executes a
later-layer script (repro), then reports PASS/FAIL for each and cleans up
the sandbox. Same script backs `ocp-prod-test-eacces-repro` below.

### Gotchas

- **Sandbox image architecture.** `podman build` on Apple Silicon produces
  an arm64 image by default; OCP cluster nodes are typically amd64, and the
  sandbox init container fails with `exec container process: Exec format
  error` if the image doesn't match the node arch. Build and push with an
  explicit platform:
  ```bash
  podman build --platform linux/amd64 -f Containerfile -t quay.io/jameswong/<image>:latest-amd64 .
  podman push quay.io/jameswong/<image>:latest-amd64
  ```
- **No `--local` on `gateway add`.** `--local` tells the CLI to extract
  mTLS certs from a gateway running in Docker on this machine — not
  applicable here, since the gateway is an OpenShift pod and
  `ocp/values-eval.yaml` disables TLS entirely. `make ocp-eval-register`
  registers it as a plain HTTP "cloud" gateway instead; the CLI will still
  try a browser OAuth flow and time out after ~120s since the server
  accepts unauthenticated requests, but the gateway is registered and
  usable regardless (`Authentication skipped` is expected, not an error).
- **Agent Sandbox is a shared, cluster-scoped dependency.**
  `ocp/install-agent-sandbox.sh` installs it and `ocp-eval-openshell-down`
  intentionally leaves it in place (other projects on the cluster may
  depend on it). The script resolves whatever asset name the latest
  upstream release actually publishes, since that asset has been renamed
  before (`manifest.yaml` → `sandbox.yaml`).

## OpenShift — Production

Separate `ocp-prod-*` targets and variables from the eval ones above — own
project, own release name, own env vars — so both can be deployed to the
same or different clusters at once without clobbering each other. Follows
the "Production" path in `docs/kubernetes/openshift.mdx` in the OpenShell
repo: a real server certificate via cert-manager, an OpenShift Route with
TLS passthrough, and OIDC for CLI auth (no `allowUnauthenticatedUsers`
bypass).

### Quickstart (new cluster, nothing set up yet)

```bash
make ocp-prod-quickstart
```

One command: installs cert-manager, bootstraps a self-signed ClusterIssuer,
deploys a dev-grade Keycloak, computes a hostname from the cluster's default
Ingress domain (`ingresses.config.openshift.io/cluster`), and deploys the
gateway. Idempotent — every step it chains is safe to re-run. Verified
end-to-end on two separate live OCP clusters, including one where the
auto-generated apps domain was long enough to trip the certificate
`commonName` 64-byte limit (see Gotchas).

Override any piece once you have real infrastructure — e.g. a real hostname
with the rest still bootstrapped:

```bash
make ocp-prod-quickstart OCP_PROD_HOSTNAME=openshell.apps.mycluster.example.com
```

Or a fully real setup (skips straight to the granular path below): set
`OCP_PROD_HOSTNAME`, `OCP_PROD_CLUSTER_ISSUER`, and `OCP_PROD_OIDC_ISSUER`
and call `make ocp-prod-openshell-up` directly instead of `quickstart`, so
you don't pay for the self-signed/Keycloak bootstrap steps.

### One-time cluster setup (granular)

If you'd rather run each piece yourself instead of `ocp-prod-quickstart`,
skip whichever you already have:

```bash
make ocp-prod-cert-manager-up            # installs cert-manager via OLM (Red Hat operator)

# If you don't have a real Issuer/ClusterIssuer yet (e.g. no ACME/corporate CA):
make ocp-prod-clusterissuer-selfsigned   # bootstraps a self-signed CA + ClusterIssuer

# If you don't have a real OIDC provider yet:
make ocp-prod-keycloak-up                # deploys a dev-grade Keycloak with a working realm
```

### Deploy

Example values below match the bootstrap self-signed issuer + dev Keycloak above:

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
make ocp-prod-register        # openshell gateway add <hostname> --oidc-issuer ... + login
make ocp-prod-test-eacces-repro  # see Diagnostics under Eval above
make ocp-prod-openshell-down
```

I've run this exact sequence end-to-end against a real OCP cluster
(self-signed issuer + dev Keycloak): the gateway comes up with `TLS
enabled`, `OIDC authentication enabled`, successfully discovers Keycloak's
JWKS, and its logged discovered issuer matches token `iss` claims exactly.
What I didn't verify is a literal `openshell gateway login` browser
round-trip, since that needs a real, browser-reachable hostname — see
"Registering the CLI" below.

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `OCP_PROD_HOSTNAME` | *(required)* | External hostname for the Route + server cert |
| `OCP_PROD_CLUSTER_ISSUER` | *(required)* | Name of an existing, `Ready` cert-manager ClusterIssuer |
| `OCP_PROD_OIDC_ISSUER` | *(required)* | OIDC issuer URL the gateway validates tokens against |
| `OCP_PROD_PROJECT` | `openshell-prod` | OpenShift project (namespace) |
| `OCP_PROD_RELEASE` | `openshell-prod` | Helm release name — must differ from eval's `openshell` (see Gotchas) |
| `OCP_PROD_CHART_VERSION` | `0.0.111` | OpenShell Helm chart version |
| `OCP_PROD_GATEWAY_NAME` | `ocp-prod` | Name used when registering with the CLI |
| `OCP_PROD_OIDC_AUDIENCE` | `openshell-cli` | Expected `aud` claim |
| `OCP_PROD_SANDBOX_IMAGE` | *(chart default)* | Default sandbox image |

The three required variables have no defaults — `ocp-prod-check` (which
`ocp-prod-openshell-up` always runs first) fails with a clear message if
any are missing, if `oc` isn't logged in, if cert-manager isn't installed,
or if the named ClusterIssuer isn't `Ready`.

### Gotchas

**Certificate `commonName` 64-byte limit.** The chart sets the external
certificate's `commonName` to the literal first `certManager.serverDnsNames`
entry, and X.509 caps CN at 64 bytes (RFC 5280). Managed OpenShift's
auto-generated apps domains (ROSA, OSD) are frequently already 50+ bytes on
their own, so a real hostname often doesn't fit — cert-manager's webhook
rejects the Certificate with `spec.commonName: Too long`. `ocp-prod-openshell-up`
works around this by always setting `serverDnsNames[0]` to a short synthetic
label (`<release>-external`, used only to keep CN short) and putting the
real hostname in `serverDnsNames[1]` as a SAN — which is what TLS clients
actually validate against (RFC 6125) and still satisfies the Route's
host-coverage check (it scans every entry, not just the first).

**Cluster-scoped RBAC naming.** The chart creates a `ClusterRole`/
`ClusterRoleBinding` named after the Helm release (`<release>-node-reader`,
etc.). Two releases with the same name anywhere on the cluster collide even
in different namespaces — this is why `OCP_PROD_RELEASE` defaults to
`openshell-prod` rather than reusing the eval path's `openshell`.

**Self-signed ClusterIssuer.** `ocp-prod-clusterissuer-selfsigned` is a
bootstrap convenience, not a substitute for a real ACME/corporate issuer:
the resulting cert is not publicly trusted, so CLI clients need the CA cert
to verify the connection (or `--gateway-insecure`). Swap in a real
`Issuer`/`ClusterIssuer` and point `OCP_PROD_CLUSTER_ISSUER` at it once you
have one.

**Dev Keycloak.**
- Deploys into its own `keycloak` namespace (not `OCP_PROD_PROJECT`) with
  an in-memory DB — state (including the imported realm) is lost on pod
  restart, but `--import-realm` re-imports it automatically.
- Test users: `admin@test` / `admin` (role `openshell-admin`) and
  `user@test` / `user` (role `openshell-user`); client `openshell-cli`
  (public, Authorization Code + PKCE and direct access grants both
  enabled).
- **Its `iss` claim always reflects the actual port a request arrived on**,
  regardless of `KC_HOSTNAME_STRICT`/`KC_HOSTNAME_PORT` settings (verified
  empirically against Keycloak 24, contradicting what those settings are
  documented to do). So the Service listens on port 9090 (not the HTTP
  default 80) — the same port used for `kubectl port-forward` — so tokens
  obtained via a local port-forward and tokens validated by the in-cluster
  gateway carry an identical `iss`. If you change `KEYCLOAK_SETUP_PORT`,
  re-verify token issuers still match before trusting the deployment.

**Registering the CLI.** Registering against a self-signed cert + a
hostname that isn't real DNS (like the `openshell-prod.example.com`
example above) won't work as-is — `openshell gateway add` needs to
actually reach the hostname and trust its certificate. For a real
deployment, point `OCP_PROD_HOSTNAME` at a real, resolvable domain; for a
local proof-of-concept against the example above, add a `/etc/hosts` entry
pointing it at an `oc port-forward`'d local address and use `openshell
gateway add --gateway-insecure` to skip cert trust.

**Sandbox image architecture** — same caveat as the [Eval](#openshift--eval) path above applies here too.

**cert-manager and Agent Sandbox are shared, cluster-scoped dependencies.**
Both are installed once per cluster; `ocp-prod-openshell-down` intentionally
leaves them in place.
