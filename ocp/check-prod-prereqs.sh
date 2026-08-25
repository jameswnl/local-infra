#!/usr/bin/env bash
# Verifies prerequisites for the production OpenShift install path
# (ocp-prod-openshell-up): required variables set, an active `oc` session,
# cert-manager installed, and the named ClusterIssuer Ready. Run standalone
# via `make ocp-prod-check`, or automatically before `ocp-prod-openshell-up`.
set -euo pipefail

HOSTNAME_ARG="${1:-}"
CLUSTER_ISSUER="${2:-}"
OIDC_ISSUER="${3:-}"

fail=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[ok]   ${label}"
  else
    echo "[FAIL] ${label}"
    fail=1
  fi
}

if [ -z "${HOSTNAME_ARG}" ]; then
  echo "[FAIL] OCP_PROD_HOSTNAME is not set"
  fail=1
fi
if [ -z "${CLUSTER_ISSUER}" ]; then
  echo "[FAIL] OCP_PROD_CLUSTER_ISSUER is not set"
  fail=1
fi
if [ -z "${OIDC_ISSUER}" ]; then
  echo "[FAIL] OCP_PROD_OIDC_ISSUER is not set"
  fail=1
fi

check "oc logged in"                oc whoami
check "cert-manager CRDs installed" kubectl get crd certificates.cert-manager.io

if [ -n "${CLUSTER_ISSUER}" ]; then
  if oc get clusterissuer "${CLUSTER_ISSUER}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
      | grep -q True; then
    echo "[ok]   ClusterIssuer '${CLUSTER_ISSUER}' is Ready"
  else
    echo "[FAIL] ClusterIssuer '${CLUSTER_ISSUER}' not found or not Ready"
    fail=1
  fi
fi

if [ "${fail}" -ne 0 ]; then
  echo ""
  echo "Set the missing variables and/or fix the cluster state, e.g.:"
  echo "  OCP_PROD_HOSTNAME=openshell.apps.example.com \\"
  echo "  OCP_PROD_CLUSTER_ISSUER=letsencrypt-prod \\"
  echo "  OCP_PROD_OIDC_ISSUER=https://keycloak.example.com/realms/openshell \\"
  echo "  make ocp-prod-openshell-up"
  exit 1
fi

echo ""
echo "All production prerequisites satisfied."
