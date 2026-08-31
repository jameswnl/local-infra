#!/usr/bin/env bash
# Builds the lightspeed-stack harness image: the official base image, then
# the Containerfile.harness overlay, which bakes in ~/ws/lightspeed-cloud-
# agents as an editable dependency via --build-context (see that file's
# header comment for why this overlay exists and the UBI10 requirement).
#
# Both source repos must be on a clean, up-to-date origin/main checkout
# (see check-clean-main.sh) so the built image never silently contains
# stale or uncommitted code. Tags the result "<stack-sha>-<agents-sha>"
# (unique whenever either repo's content changes) plus a fixed ALIAS_TAG
# for manifests to reference, then either pushes both tags to a registry
# or loads both into a Kind cluster.
#
# Required env: STACK_REPO AGENTS_REPO IMAGE_REPO ALIAS_TAG PLATFORM
# Optional env: PUSH (default false) KIND_CLUSTER (required when PUSH=false)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${STACK_REPO:?STACK_REPO is required}"
: "${AGENTS_REPO:?AGENTS_REPO is required}"
: "${IMAGE_REPO:?IMAGE_REPO is required}"
: "${ALIAS_TAG:?ALIAS_TAG is required}"
: "${PLATFORM:?PLATFORM is required}"
PUSH="${PUSH:-false}"

STACK_SHA=$("$SCRIPT_DIR/check-clean-main.sh" "$STACK_REPO")
AGENTS_SHA=$("$SCRIPT_DIR/check-clean-main.sh" "$AGENTS_REPO")
TAG="${STACK_SHA}-${AGENTS_SHA}"

echo "[build-lightspeed-stack] $STACK_REPO@$STACK_SHA + $AGENTS_REPO@$AGENTS_SHA -> ${IMAGE_REPO}:${TAG}" >&2

BASE_TAG="localhost/lightspeed-stack:build-base-${TAG}"

podman build --platform "$PLATFORM" \
  --build-arg BUILDER_BASE_IMAGE=registry.access.redhat.com/ubi10/python-312-minimal \
  --build-arg BUILDER_DNF_COMMAND=microdnf \
  --build-arg RUNTIME_BASE_IMAGE=registry.access.redhat.com/ubi10/python-312-minimal \
  --build-arg RUNTIME_DNF_COMMAND=microdnf \
  -f "$STACK_REPO/deploy/lightspeed-stack/Containerfile" \
  -t "$BASE_TAG" \
  "$STACK_REPO"

podman build \
  --build-context "cloud_agents=$AGENTS_REPO" \
  --build-arg "BASE_IMAGE=$BASE_TAG" \
  -f "$STACK_REPO/deploy/lightspeed-stack/Containerfile.harness" \
  -t "${IMAGE_REPO}:${TAG}" \
  "$STACK_REPO"

podman tag "${IMAGE_REPO}:${TAG}" "${IMAGE_REPO}:${ALIAS_TAG}"

if [ "$PUSH" = "true" ]; then
  podman push "${IMAGE_REPO}:${TAG}"
  podman push "${IMAGE_REPO}:${ALIAS_TAG}"
else
  : "${KIND_CLUSTER:?KIND_CLUSTER is required when PUSH=false}"
  KIND_EXPERIMENTAL_PROVIDER=podman kind load docker-image "${IMAGE_REPO}:${TAG}" --name "$KIND_CLUSTER"
  KIND_EXPERIMENTAL_PROVIDER=podman kind load docker-image "${IMAGE_REPO}:${ALIAS_TAG}" --name "$KIND_CLUSTER"
fi

echo "${IMAGE_REPO}:${TAG}"
