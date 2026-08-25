#!/usr/bin/env bash
# Deploys a dev-grade Keycloak into the "keycloak" namespace, pre-loaded
# with the "openshell" realm (test users, roles, and an "openshell-cli"
# public client configured for Authorization Code + PKCE and direct access
# grants). Adapted from the OpenShell repo's own
# tasks/scripts/keycloak-k8s-setup.sh (used for its local k3s dev/e2e setup).
#
# NOT production-hardened: in-memory H2 database (state lost on pod
# restart), admin/admin credentials, HTTP only. Use this to prove out the
# OIDC production path end-to-end; swap in a real IdP for anything durable.
#
# Idempotent: kubectl apply + Keycloak's --import-realm (which skips the
# realm if it already exists).
#
# KC_HOSTNAME is pinned to the in-cluster Service DNS name so the `iss`
# claim's host is stable. The PORT in `iss`, however, always reflects
# whatever port the request actually arrived on (Keycloak 24 does this
# regardless of KC_HOSTNAME_STRICT/KC_HOSTNAME_PORT settings — tested empirically,
# not just per docs). To keep `iss` identical whether a token was obtained
# in-cluster (gateway -> Service) or via a local port-forward (human -> CLI
# login), the Service itself listens on SETUP_PORT instead of the HTTP
# default (80), so both paths connect on the same port number and produce
# the same `iss`. Do not "simplify" this back to port 80 without re-verifying
# token issuers match under an actual port-forward.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="keycloak"
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:24.0}"
ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
SETUP_PORT="${KEYCLOAK_SETUP_PORT:-9090}"
REALM_FILE="${SCRIPT_DIR}/keycloak-realm.json"
HEALTH_TIMEOUT="${KEYCLOAK_HEALTH_TIMEOUT:-120}"

SVC_HOSTNAME="keycloak.${NAMESPACE}.svc.cluster.local"

if [ ! -f "${REALM_FILE}" ]; then
  echo "error: realm file not found: ${REALM_FILE}" >&2
  exit 1
fi

echo "Creating namespace '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "Applying realm ConfigMap..."
kubectl -n "${NAMESPACE}" create configmap openshell-realm \
  --from-file=realm.json="${REALM_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Applying Keycloak Deployment and Service..."
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: ${KEYCLOAK_IMAGE}
          args: ["start-dev", "--import-realm"]
          env:
            - name: KEYCLOAK_ADMIN
              value: "${ADMIN_USER}"
            - name: KEYCLOAK_ADMIN_PASSWORD
              value: "${ADMIN_PASSWORD}"
            - name: KC_HOSTNAME
              value: "${SVC_HOSTNAME}"
            - name: KC_HOSTNAME_STRICT
              value: "false"
            - name: KC_HOSTNAME_STRICT_HTTPS
              value: "false"
            - name: KC_HTTP_ENABLED
              value: "true"
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /realms/master
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 5
            failureThreshold: 12
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              memory: 1Gi
          volumeMounts:
            - name: realm
              mountPath: /opt/keycloak/data/import
      volumes:
        - name: realm
          configMap:
            name: openshell-realm
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  selector:
    app: keycloak
  ports:
    - port: ${SETUP_PORT}
      targetPort: 8080
EOF

echo "Waiting for Keycloak to be ready (up to ${HEALTH_TIMEOUT}s)..."
kubectl rollout status deployment/keycloak -n "${NAMESPACE}" --timeout="${HEALTH_TIMEOUT}s"

ISSUER="http://${SVC_HOSTNAME}:${SETUP_PORT}/realms/openshell"

echo ""
echo "Keycloak is ready."
echo ""
echo "  In-cluster issuer:  ${ISSUER}"
echo ""
echo "  Use it with:"
echo "    OCP_PROD_OIDC_ISSUER=${ISSUER} make ocp-prod-openshell-up"
echo ""
echo "  To get a token for manual testing, keep a port-forward running:"
echo "    kubectl -n ${NAMESPACE} port-forward svc/keycloak ${SETUP_PORT}:${SETUP_PORT}"
echo ""
echo "  Test users (token endpoint: http://localhost:${SETUP_PORT}/realms/openshell/protocol/openid-connect/token):"
echo "    admin@test / admin  (role: openshell-admin)"
echo "    user@test  / user   (role: openshell-user)"
echo ""
echo "  Get a token:"
echo "    curl -s -X POST http://localhost:${SETUP_PORT}/realms/openshell/protocol/openid-connect/token \\"
echo "      -d 'grant_type=password&client_id=openshell-cli&username=admin@test&password=admin' \\"
echo "      | jq -r .access_token"
echo ""
