#!/usr/bin/env bash
# Installs cert-manager on OpenShift via OLM, using Red Hat's official
# "cert-manager Operator for Red Hat OpenShift" (redhat-operators catalog)
# rather than the upstream Helm chart. Idempotent — skips if the Subscription
# already exists.
#
# Creates the operator in the cert-manager-operator namespace (AllNamespaces
# install mode); the operator then runs the cert-manager operand pods in the
# cert-manager namespace.
set -euo pipefail

if oc get subscription openshift-cert-manager-operator -n cert-manager-operator >/dev/null 2>&1; then
  echo "cert-manager operator subscription already exists, skipping install."
else
  cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces: []
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
fi

echo "Waiting for the operator CSV to succeed..."
for _ in $(seq 1 36); do
  csv=$(oc get subscription openshift-cert-manager-operator -n cert-manager-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  if [ -n "${csv}" ]; then
    phase=$(oc get csv "${csv}" -n cert-manager-operator -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "${phase}" = "Succeeded" ]; then
      echo "Operator CSV ${csv}: Succeeded"
      break
    fi
  fi
  sleep 5
done

echo "Waiting for cert-manager operand pods..."
oc -n cert-manager wait --for=condition=Available deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector --timeout=180s
echo "cert-manager is running."
