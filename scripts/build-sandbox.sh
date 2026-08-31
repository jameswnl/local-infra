#!/usr/bin/env bash
# Builds the lightspeed-agentic-sandbox image (the production Containerfile,
# matching what OCP actually runs) from a clean, up-to-date origin/main
# checkout (see check-clean-main.sh), tagged with its commit SHA plus a
# fixed alias tag, and pushes both to the registry.
#
# Required env: SANDBOX_REPO IMAGE_REPO ALIAS_TAG PLATFORM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${SANDBOX_REPO:?SANDBOX_REPO is required}"
: "${IMAGE_REPO:?IMAGE_REPO is required}"
: "${ALIAS_TAG:?ALIAS_TAG is required}"
: "${PLATFORM:?PLATFORM is required}"

SHA=$("$SCRIPT_DIR/check-clean-main.sh" "$SANDBOX_REPO")

echo "[build-sandbox] $SANDBOX_REPO@$SHA -> ${IMAGE_REPO}:${SHA}" >&2

podman build --platform "$PLATFORM" \
  -f "$SANDBOX_REPO/Containerfile" \
  -t "${IMAGE_REPO}:${SHA}" \
  "$SANDBOX_REPO"

podman tag "${IMAGE_REPO}:${SHA}" "${IMAGE_REPO}:${ALIAS_TAG}"

podman push "${IMAGE_REPO}:${SHA}"
podman push "${IMAGE_REPO}:${ALIAS_TAG}"

echo "${IMAGE_REPO}:${SHA}"
