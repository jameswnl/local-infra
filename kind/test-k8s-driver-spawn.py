"""Real spawn test against the Kind OpenShell gateway via the kubernetes
compute driver -- the same production code path
(build_spawner -> spawn -> health check -> destroy) already verified
end-to-end on real OCP (see
~/ws/lightspeed-stack/docs/design/cloud-agents/prod/ocp-sandbox-file-read-eacces.md).

Unlike `oc exec`-based repro scripts, this goes through the gateway's own
gRPC API and the sandbox's real HTTP server, so it genuinely exercises
supervisor-mediated Landlock enforcement rather than bypassing it via a
direct container-runtime attach.

Requires a Python environment with `cloud_agents` and `openshell` installed,
e.g.:
    cd ~/ws/lightspeed-cloud-agents && source .venv/bin/activate

Run via `make kind-openshell-test-spawn` (handles the port-forward), or
directly with OPENSHELL_GATEWAY_URL pointed at an already-forwarded gateway.
"""

import asyncio
import os

import httpx

from cloud_agents.spawner.factory import build_spawner

GATEWAY_URL = os.environ.get("OPENSHELL_GATEWAY_URL", "localhost:9090")
SANDBOX_IMAGE = os.environ.get(
    "OPENSHELL_SANDBOX_IMAGE",
    "quay.io/jameswong/lightspeed-agentic-sandbox:latest-arm64",
)


async def main() -> None:
    """Spawn a real sandbox via the kubernetes driver and verify it's healthy."""
    spawner = build_spawner(
        "openshell",
        gateway_url=GATEWAY_URL,
        driver="kubernetes",
        workspace="default",
    )
    name = "k8s-driver-kind-verify"
    try:
        endpoint = await spawner.spawn(
            name,
            SANDBOX_IMAGE,
            env={"LIGHTSPEED_PROVIDER": "openai", "LIGHTSPEED_MODEL": "gpt-4o-mini"},
            read_only=False,
        )
        print("SPAWN SUCCEEDED, endpoint:", endpoint)

        headers = spawner.get_sandbox_headers(name)
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(f"{endpoint}/health", headers=headers)
        print("health status:", resp.status_code)
        assert resp.status_code == 200
    finally:
        await spawner.destroy(name)
        print("destroyed cleanly")


if __name__ == "__main__":
    asyncio.run(main())
