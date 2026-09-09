#!/usr/bin/env python3
"""Mock pod-status MCP server.

Exposes deterministic tools (`get_pod_status`, `get_pods`, `describe_pod`,
`get_pod_logs`), so an agent loop has real external tools to call. The
canned answers are intentionally specific (restarts=7, memoryLimit=347Mi)
so a caller can tell from the model's reply that the tools were actually
invoked rather than hallucinated -- a model won't emit `347Mi` on its
own. The pod inventory centers on `checkout-7f9` (OOMKilled triage story)
to back the k8s-diag skill demos.

Backs the lightspeed-stack `*-none-tools` demo scenarios and e2e seam
test: point a run at this server via the run-level MCP catalog, e.g.
`mcp_servers: [{"name": "pod-status", "url": "<this>/mcp"}]`, and declare
`mcp_servers: ["pod-status"]` on the step. In-cluster URLs:
- Kind:  http://mcp-pod-status-mock:8084/mcp (namespace `openshell`)
- OCP:    http://mcp-pod-status-mock:8084/mcp (namespace `openshell-prod`)

Uses the `mcp` SDK's bundled FastMCP server (mcp.server.fastmcp),
not the slim standalone `fastmcp` package.

Usage:
    # Serves streamable-http on http://127.0.0.1:8084/mcp by default.
    python3 server.py

    # Override host/port:
    DEMO_MCP_HOST=0.0.0.0 DEMO_MCP_PORT=9200 python3 server.py

Deploy:
    make kind-mcp-pod-status-up        # build + load + deploy to Kind
    make ocp-prod-mcp-pod-status-up    # build + push + deploy to OCP prod
"""

from __future__ import annotations

import os

from mcp.server.fastmcp import FastMCP

HOST = os.environ.get("DEMO_MCP_HOST", "127.0.0.1")


def _port() -> int:
    try:
        return int(os.environ.get("DEMO_MCP_PORT", "8084"))
    except ValueError:
        return 8084


PORT = _port()

mcp = FastMCP("pod-status-mock", host=HOST, port=PORT)


@mcp.tool()
def get_pod_status(pod_name: str) -> str:
    """Return the current status of a Kubernetes pod by name.

    Parameters:
        pod_name: The name of the pod to look up.

    Returns:
        A short human-readable status string. memoryLimit is a deliberately
        odd, non-default value (347Mi) that a model won't emit on its own --
        so seeing it echoed back proves the tool was actually called rather
        than the answer hallucinated.
    """
    return (
        f"Pod {pod_name}: phase=Running, restarts=7, "
        "lastState=CrashLoopBackOff, reason=OOMKilled, memoryLimit=347Mi"
    )


@mcp.tool()
def get_pods(namespace: str = "default") -> str:
    """List pods in a namespace with phase and restart counts.

    Parameters:
        namespace: Namespace to list (canned data ignores it).

    Returns:
        A short human-readable pod list. `checkout-7f9` carries the
        OOMKilled triage story told by the sibling tools.
    """
    return (
        f"Pods in namespace '{namespace}':\n"
        "- checkout-7f9: phase=Running, restarts=7, ready=1/1\n"
        "- payments-5d8: phase=Running, restarts=0, ready=1/1\n"
        "- search-2c1: phase=Running, restarts=1, ready=1/1"
    )


@mcp.tool()
def describe_pod(pod_name: str, namespace: str = "default") -> str:
    """Describe a pod: containers, state, events.

    Parameters:
        pod_name: Name of the pod to describe.
        namespace: Namespace of the pod (canned data ignores it).

    Returns:
        A short human-readable pod description. Unknown names report
        NotFound so the agent can react instead of guessing.
    """
    if pod_name != "checkout-7f9":
        return f"Pod {pod_name}: NotFound in namespace '{namespace}'"
    return (
        f"Pod {pod_name} (namespace '{namespace}'): phase=Running, "
        "containers=[app], image=quay.io/demo/checkout:1.4.2, "
        "limits=memory:347Mi, lastState=CrashLoopBackOff "
        "(reason=OOMKilled, exitCode=137), "
        "events=[Liveness probe failed x3, OOMKilled]"
    )


@mcp.tool()
def get_pod_logs(
    pod_name: str, namespace: str = "default", tail_lines: int = 50
) -> str:
    """Return recent log lines for a pod.

    Parameters:
        pod_name: Name of the pod.
        namespace: Namespace of the pod (canned data ignores it).
        tail_lines: How many trailing lines to return (canned data
            always returns the same short excerpt).

    Returns:
        Canned log excerpt ending in the OOM kill for `checkout-7f9`,
        NotFound for unknown names.
    """
    _ = (namespace, tail_lines)
    if pod_name != "checkout-7f9":
        return f"Pod {pod_name}: no logs (NotFound)"
    return (
        f"Logs for {pod_name} (last 5 lines):\n"
        "INFO checkout: processed 1204 orders\n"
        "INFO checkout: cart total computed in 41ms\n"
        "WARN runtime: heap 341Mi approaching limit 347Mi\n"
        "FATAL runtime: out of memory, killing container\n"
        "INFO kubelet: container reason=OOMKilled exitCode=137"
    )


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
