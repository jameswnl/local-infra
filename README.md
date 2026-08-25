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

## Architecture

```
openshell CLI ──▶ gateway (:8080, Podman driver)
                    ├──▶ sandbox containers (via Podman socket)
                    └──▶ OTel Collector (:4317)
                           ├──▶ Jaeger (:16686)
                           └──▶ debug (stdout)
```
