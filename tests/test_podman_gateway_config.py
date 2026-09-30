"""Tests for the local Podman OpenShell gateway configuration."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
PINNED_GATEWAY_IMAGE = "ghcr.io/nvidia/openshell/gateway:0.0.116"


class PodmanGatewayConfigTests(unittest.TestCase):
    """Validate the gateway config against the current OpenShell contract."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the gateway configuration once for the test class."""
        with (ROOT / "gateway.toml").open("rb") as config_file:
            cls.config = tomllib.load(config_file)

    def test_uses_current_gateway_schema_and_driver_selection(self) -> None:
        """Use the schema and driver selection supported by the pinned gateway."""
        gateway = self.config["openshell"]["gateway"]

        self.assertEqual(self.config["openshell"]["version"], 1)
        self.assertEqual(gateway["compute_drivers"], ["podman"])
        podman_driver = self.config["openshell"]["drivers"]["podman"]
        self.assertEqual(
            podman_driver["grpc_endpoint"],
            "http://host.containers.internal:8080",
        )
        self.assertEqual(podman_driver["image_pull_policy"], "missing")

    def test_pinned_gateway_matches_supported_client_protocol(self) -> None:
        """Keep the gateway tag aligned with the installed OpenShell client."""
        result = subprocess.run(
            ["podman", "run", "--rm", PINNED_GATEWAY_IMAGE, "--version"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            result.returncode,
            0,
            msg=f"gateway version check failed:\n{result.stdout}\n{result.stderr}",
        )
        self.assertIn("openshell-gateway 0.0.116", result.stdout)

    def test_compose_config_is_valid(self) -> None:
        """Ensure Compose can render the checked-in service definition."""
        result = subprocess.run(
            ["podman", "compose", "-f", str(ROOT / "docker-compose.yaml"), "config"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            result.returncode,
            0,
            msg=f"compose config failed:\n{result.stdout}\n{result.stderr}",
        )

    def test_compose_uses_named_cert_volume_without_external_requirement(self) -> None:
        """Let the startup target create the JWT volume on a fresh machine."""
        compose = (ROOT / "docker-compose.yaml").read_text()
        makefile = (ROOT / "Makefile").read_text()

        self.assertIn("openshell-certs:/certs:ro", compose)
        self.assertIn(
            "image: ghcr.io/nvidia/openshell/gateway:${IMAGE_TAG:-0.0.116}",
            compose,
        )
        self.assertIn('127.0.0.1:8080:8080', compose)
        self.assertIn('127.0.0.1:8081:8081', compose)
        self.assertNotIn("openshell-certs:\n    external: true", compose)
        self.assertIn("IMAGE_TAG                 ?= 0.0.116", makefile)
        self.assertIn("curl -sf http://localhost:8081/healthz", makefile)


if __name__ == "__main__":
    unittest.main()
