# OTel Collector + Jaeger

Standalone observability stack for local development. Receives OpenTelemetry traces and visualizes them in Jaeger.

## Quick start

```bash
make up        # start collector + jaeger
make jaeger    # open Jaeger UI in browser
```

Jaeger UI: http://localhost:16686

## Endpoints

| Service        | Protocol | Address                |
|----------------|----------|------------------------|
| OTel Collector | gRPC     | `grpc://localhost:4317` |
| OTel Collector | HTTP     | `http://localhost:4318` |
| Jaeger UI      | HTTP     | `http://localhost:16686`|

## Usage with cloud-agents

Start this stack first, then point the workflow runner at the collector:

```bash
# Terminal 1 — start otel infra
cd ~/ws/otel-infra
make up

# Terminal 2 — start cloud-agents with tracing enabled
cd ~/ws/lightspeed-cloud-agents
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 make up
```

Or set the env var in the compose override:

```yaml
services:
  workflow-runner:
    environment:
      OTEL_EXPORTER_OTLP_ENDPOINT: http://host.containers.internal:4317
      OTEL_SERVICE_NAME: cloud-agents
```

> Use `host.containers.internal` when the workflow runner runs in a container
> and the collector runs on the host (or in a separate compose stack).

## Make targets

```
make up        Start OTel Collector + Jaeger
make down      Stop everything
make logs      Tail OTel collector logs
make jaeger    Open Jaeger UI in browser
make status    Show running containers
```

## Architecture

```
app (OTLP gRPC/HTTP)
  └─▶ OTel Collector (:4317/:4318)
        ├─▶ Jaeger (:4317 OTLP) ──▶ Jaeger UI (:16686)
        └─▶ debug (stdout)
```

The collector uses `otel-collector-config.yaml` which batches spans and exports to Jaeger via OTLP and to stdout via the debug exporter.
