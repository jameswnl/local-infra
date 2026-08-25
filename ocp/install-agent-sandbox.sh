#!/usr/bin/env bash
# Installs the Agent Sandbox controller + CRDs (a required OpenShell
# dependency for the Kubernetes/OpenShift compute driver) on whatever
# cluster the current kubectl/oc context points at. Idempotent: skips if
# the CRD is already present.
#
# Resolves the latest kubernetes-sigs/agent-sandbox release and applies its
# "sandbox.yaml" asset, instead of hardcoding a release URL — the upstream
# project has renamed this asset before (it used to be "manifest.yaml").
set -euo pipefail

REPO="kubernetes-sigs/agent-sandbox"

if kubectl get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1; then
  echo "Agent Sandbox CRD already installed, skipping."
  exit 0
fi

TAG=$(curl -sSL "https://api.github.com/repos/${REPO}/releases/latest" | grep -m1 '"tag_name"' | cut -d '"' -f4)
if [ -z "${TAG}" ]; then
  echo "error: could not resolve latest ${REPO} release tag" >&2
  exit 1
fi

MANIFEST_URL="https://github.com/${REPO}/releases/download/${TAG}/sandbox.yaml"
echo "Installing Agent Sandbox ${TAG} from ${MANIFEST_URL}"
kubectl apply -f "${MANIFEST_URL}"
kubectl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=120s
