#!/usr/bin/env bash
# Bootstraps a self-signed root CA and a "ca"-type ClusterIssuer from it,
# for use as OCP_PROD_CLUSTER_ISSUER when no real ACME/corporate issuer is
# available yet. Idempotent — skips creation if the ClusterIssuer exists.
#
# cert-manager requires a two-step bootstrap for a reusable self-signed CA
# (a bare "selfSigned" issuer can only mint a single self-signed leaf cert,
# not sign further certificates):
#   1. A temporary selfSigned ClusterIssuer mints a root CA Certificate.
#   2. A "ca"-type ClusterIssuer then issues leaf certs from that CA's key.
#
# The CA secret must live in cert-manager's cluster-resource-namespace
# (this cluster's cert-manager runs with --cluster-resource-namespace set
# to its own pod namespace, i.e. "cert-manager").
set -euo pipefail

ISSUER_NAME="${1:-openshell-selfsigned-ca}"
CA_SECRET_NAME="${2:-openshell-selfsigned-ca-tls}"
CA_NAMESPACE="${3:-cert-manager}"

if oc get clusterissuer "${ISSUER_NAME}" >/dev/null 2>&1; then
  echo "ClusterIssuer '${ISSUER_NAME}' already exists, skipping."
  exit 0
fi

cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ISSUER_NAME}-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${ISSUER_NAME}-root
  namespace: ${CA_NAMESPACE}
spec:
  isCA: true
  commonName: ${ISSUER_NAME}
  secretName: ${CA_SECRET_NAME}
  duration: 87600h  # 10y
  renewBefore: 720h # 30d
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: ${ISSUER_NAME}-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ISSUER_NAME}
spec:
  ca:
    secretName: ${CA_SECRET_NAME}
EOF

echo "Waiting for root CA certificate to be issued..."
oc -n "${CA_NAMESPACE}" wait --for=condition=Ready "certificate/${ISSUER_NAME}-root" --timeout=120s

echo "Waiting for ClusterIssuer '${ISSUER_NAME}' to be ready..."
for _ in $(seq 1 24); do
  status=$(oc get clusterissuer "${ISSUER_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "${status}" = "True" ]; then
    echo "ClusterIssuer '${ISSUER_NAME}' is Ready."
    exit 0
  fi
  sleep 5
done

echo "error: ClusterIssuer '${ISSUER_NAME}' did not become Ready in time" >&2
exit 1
