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

## Architecture

```
openshell CLI ──▶ gateway (:8080, Podman driver)
                    ├──▶ sandbox containers (via Podman socket)
                    └──▶ OTel Collector (:4317)
                           ├──▶ Jaeger (:16686)
                           └──▶ debug (stdout)
```
