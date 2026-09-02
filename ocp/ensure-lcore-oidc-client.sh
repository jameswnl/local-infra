#!/usr/bin/env bash
# Ensures the confidential service-account OIDC client "lcore-agents" exists
# on the running dev Keycloak (namespace "keycloak", realm "openshell"),
# reads back its client secret and service-account user id (the "sub" the
# gateway sees), and wires both into the places lightspeed-stack needs them:
#
#   1. ./.env.ocp-prod                          -- for a LOCAL `uv run` of the
#                                                  stack against the external
#                                                  gateway route.
#   2. Secret lightspeed-stack-openshell-oidc   -- in the OCP_PROD_PROJECT
#      (namespace)                                 namespace, consumed by the
#                                                  in-cluster Deployment in
#                                                  ocp/lightspeed-stack.yaml.
#
# Why a script (and not just realm.json): the realm import (install-dev-
# keycloak.sh --import-realm) is skipped if the realm already exists, so on
# an already-running Keycloak the declarative lcore-agents client in
# keycloak-realm.json never gets applied. This script uses kcadm.sh inside
# the Keycloak pod to create-if-missing, so both the fresh-import path and
# the already-running path converge on the same client. It is idempotent.
#
# The client mirrors the realm.json definition: confidential, service
# accounts enabled, standard/direct-access flows off, and an audience mapper
# that stamps aud=openshell-cli so the gateway (deployed with
# server.oidc.audience=openshell-cli) accepts the token.
#
# NOT production-hardened -- this targets the dev-grade Keycloak from
# install-dev-keycloak.sh (admin/admin, in-memory H2, HTTP). Swap in a real
# IdP + secret management for anything durable.
#
# Required (positional or env):
#   OIDC_ISSUER    issuer URL the gateway validates against, e.g.
#                  http://keycloak-openshell-prod.apps.example.com/realms/openshell
#   GATEWAY_URL    gateway endpoint for the LOCAL stack run, e.g.
#                  https://openshell-prod-openshell-prod.apps.example.com
#
# Optional env (with defaults):
#   KEYCLOAK_NAMESPACE      keycloak
#   KEYCLOAK_ADMIN_USER     admin
#   KEYCLOAK_ADMIN_PASSWORD admin
#   REALM                   openshell
#   CLIENT_ID               lcore-agents
#   OIDC_AUDIENCE           openshell-cli
#   TARGET_NAMESPACE        openshell-prod   (where the k8s secret is created)
#   OIDC_SECRET_NAME        lightspeed-stack-openshell-oidc
#   ENV_FILE                ./.env.ocp-prod
#   WORKSPACE               default          (gateway workspace to grant the
#                                             service account membership in)
#   GATEWAY_NAME            ocp-prod         (openshell CLI gateway name used
#                                             to add the workspace member)
#   GATEWAY_INSECURE        true             (pass --gateway-insecure to the
#                                             CLI; the gateway's self-signed
#                                             CA isn't in the CLI's trust store)
#   SKIP_WORKSPACE_MEMBER   (unset)          set to any value to skip the
#                                             workspace-membership step
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OIDC_ISSUER="${OIDC_ISSUER:-${1:-}}"
GATEWAY_URL="${GATEWAY_URL:-${2:-}}"

KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="${REALM:-openshell}"
CLIENT_ID="${CLIENT_ID:-lcore-agents}"
OIDC_AUDIENCE="${OIDC_AUDIENCE:-openshell-cli}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-openshell-prod}"
OIDC_SECRET_NAME="${OIDC_SECRET_NAME:-lightspeed-stack-openshell-oidc}"
ENV_FILE="${ENV_FILE:-${REPO_DIR}/.env.ocp-prod}"
WORKSPACE="${WORKSPACE:-default}"
GATEWAY_NAME="${GATEWAY_NAME:-ocp-prod}"
GATEWAY_INSECURE="${GATEWAY_INSECURE:-true}"
OPENSHELL_CLI="${OPENSHELL_CLI:-openshell}"

KCADM="/opt/keycloak/bin/kcadm.sh"

if [ -z "${OIDC_ISSUER}" ] || [ -z "${GATEWAY_URL}" ]; then
  echo "error: OIDC_ISSUER and GATEWAY_URL are required." >&2
  echo "  usage: $0 <OIDC_ISSUER> <GATEWAY_URL>" >&2
  echo "  e.g.:  $0 http://keycloak-openshell-prod.apps.example.com/realms/openshell \\" >&2
  echo "            https://openshell-prod-openshell-prod.apps.example.com" >&2
  exit 1
fi

# All kcadm calls run inside the Keycloak pod against its own localhost:8080,
# so admin creds never traverse the network and we don't depend on the Route.
#
# --config points kcadm at a writable path: OpenShift runs the pod under an
# arbitrary non-root UID whose $HOME is "/", so kcadm's default
# $HOME/.keycloak/kcadm.config location isn't writable. /tmp is. The login
# token cache persists there across exec calls within the same pod.
KCADM_CONFIG="/tmp/kcadm.config"
kc() {
  oc -n "${KEYCLOAK_NAMESPACE}" exec deploy/keycloak -- "${KCADM}" "$@" --config "${KCADM_CONFIG}"
}

echo "[lcore-client] Authenticating kcadm as ${ADMIN_USER} (in-pod)..."
kc config credentials --server http://localhost:8080 --realm master \
  --user "${ADMIN_USER}" --password "${ADMIN_PASSWORD}" >/dev/null

# Look up the client's internal id (empty if it doesn't exist yet).
lookup_client_uuid() {
  kc get clients -r "${REALM}" -q "clientId=${CLIENT_ID}" --fields id --format csv --noquotes 2>/dev/null \
    | tr -d '\r' | grep -v '^$' | head -n1
}

CLIENT_UUID="$(lookup_client_uuid || true)"

if [ -n "${CLIENT_UUID}" ]; then
  echo "[lcore-client] Client '${CLIENT_ID}' already exists (${CLIENT_UUID}) -- leaving as-is."
else
  echo "[lcore-client] Creating confidential service-account client '${CLIENT_ID}'..."
  kc create clients -r "${REALM}" \
    -s "clientId=${CLIENT_ID}" \
    -s "name=Lightspeed Core Agents" \
    -s "description=Confidential service-account client for lightspeed-stack (Client Credentials grant)" \
    -s "enabled=true" \
    -s "publicClient=false" \
    -s "serviceAccountsEnabled=true" \
    -s "standardFlowEnabled=false" \
    -s "directAccessGrantsEnabled=false" \
    -s "protocol=openid-connect" \
    -s "fullScopeAllowed=true" >/dev/null
  CLIENT_UUID="$(lookup_client_uuid)"
  if [ -z "${CLIENT_UUID}" ]; then
    echo "error: created client '${CLIENT_ID}' but could not read its id back." >&2
    exit 1
  fi
  echo "[lcore-client] Created (${CLIENT_UUID}). Adding aud=${OIDC_AUDIENCE} mapper..."
  kc create "clients/${CLIENT_UUID}/protocol-mappers/models" -r "${REALM}" \
    -s "name=${CLIENT_ID} audience" \
    -s "protocol=openid-connect" \
    -s "protocolMapper=oidc-audience-mapper" \
    -s 'config."included.client.audience"='"${OIDC_AUDIENCE}" \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."introspection.token.claim"=true' >/dev/null
fi

echo "[lcore-client] Reading client secret..."
CLIENT_SECRET="$(kc get "clients/${CLIENT_UUID}/client-secret" -r "${REALM}" 2>/dev/null \
  | tr -d '\r' | grep -o '"value"[^,}]*' | sed 's/.*: *"\(.*\)".*/\1/' | head -n1)"
if [ -z "${CLIENT_SECRET}" ]; then
  echo "[lcore-client] No secret yet -- generating one..."
  kc create "clients/${CLIENT_UUID}/client-secret" -r "${REALM}" >/dev/null
  CLIENT_SECRET="$(kc get "clients/${CLIENT_UUID}/client-secret" -r "${REALM}" 2>/dev/null \
    | tr -d '\r' | grep -o '"value"[^,}]*' | sed 's/.*: *"\(.*\)".*/\1/' | head -n1)"
fi
if [ -z "${CLIENT_SECRET}" ]; then
  echo "error: could not read a client secret for '${CLIENT_ID}'." >&2
  exit 1
fi

echo "[lcore-client] Reading service-account user id (the gateway-visible sub)..."
SA_SUBJECT="$(kc get "clients/${CLIENT_UUID}/service-account-user" -r "${REALM}" 2>/dev/null \
  | tr -d '\r' | grep -o '"id"[^,}]*' | sed 's/.*: *"\(.*\)".*/\1/' | head -n1)"
if [ -z "${SA_SUBJECT}" ]; then
  echo "warning: could not read the service-account user id -- leaving SA_SUBJECT empty." >&2
fi

echo "[lcore-client] Writing ${ENV_FILE}..."
printf 'OPENSHELL_OIDC_CLIENT_SECRET=%s\nOPENSHELL_OIDC_CLIENT_ID=%s\nOPENSHELL_OIDC_ISSUER=%s\nOPENSHELL_OIDC_AUDIENCE=%s\nOPENSHELL_GATEWAY_URL=%s\nOPENSHELL_SA_SUBJECT=%s\n' \
  "${CLIENT_SECRET}" "${CLIENT_ID}" "${OIDC_ISSUER}" "${OIDC_AUDIENCE}" "${GATEWAY_URL}" "${SA_SUBJECT}" > "${ENV_FILE}"

echo "[lcore-client] Creating/updating Secret ${OIDC_SECRET_NAME} in namespace ${TARGET_NAMESPACE}..."
oc -n "${TARGET_NAMESPACE}" create secret generic "${OIDC_SECRET_NAME}" \
  --from-literal=OPENSHELL_OIDC_ISSUER="${OIDC_ISSUER}" \
  --from-literal=OPENSHELL_OIDC_CLIENT_ID="${CLIENT_ID}" \
  --from-literal=OPENSHELL_OIDC_CLIENT_SECRET="${CLIENT_SECRET}" \
  --from-literal=OPENSHELL_OIDC_AUDIENCE="${OIDC_AUDIENCE}" \
  --dry-run=client -o yaml | oc apply -f -

# Authentication (a valid token) is necessary but not sufficient: the gateway
# also authorizes by workspace membership, keyed on the token's subject. A
# freshly-created service account is a member of no workspace, so every RPC
# fails with PERMISSION_DENIED ("not a member of workspace ...") until its
# subject is added. This is why OPENSHELL_SA_SUBJECT exists -- it's the id we
# grant membership to here. Uses the openshell CLI (already logged in as an
# admin by `make ocp-prod-register`); --gateway-insecure because the gateway's
# self-signed CA isn't in the CLI's trust store.
if [ -n "${SKIP_WORKSPACE_MEMBER:-}" ]; then
  echo "[lcore-client] SKIP_WORKSPACE_MEMBER set -- skipping workspace membership grant."
elif [ -z "${SA_SUBJECT}" ]; then
  echo "warning: SA subject unknown -- cannot grant workspace membership. The stack" >&2
  echo "         will get PERMISSION_DENIED until you add it manually." >&2
elif ! command -v "${OPENSHELL_CLI}" >/dev/null 2>&1; then
  echo "warning: '${OPENSHELL_CLI}' CLI not found -- skipping workspace membership grant." >&2
  echo "         Grant it manually, then the stack can spawn:" >&2
  echo "         ${OPENSHELL_CLI} workspace member add --workspace ${WORKSPACE} --subject ${SA_SUBJECT} --role user" >&2
else
  insecure_flag=""
  if [ "${GATEWAY_INSECURE}" = "true" ]; then insecure_flag="--gateway-insecure"; fi
  echo "[lcore-client] Ensuring service account ${SA_SUBJECT} is a member of workspace '${WORKSPACE}'..."
  if "${OPENSHELL_CLI}" ${insecure_flag} -g "${GATEWAY_NAME}" workspace member list --workspace "${WORKSPACE}" 2>/dev/null \
      | grep -q "${SA_SUBJECT}"; then
    echo "[lcore-client] Already a member of '${WORKSPACE}'."
  else
    "${OPENSHELL_CLI}" ${insecure_flag} -g "${GATEWAY_NAME}" workspace member add \
      --workspace "${WORKSPACE}" --subject "${SA_SUBJECT}" --role user
  fi
fi

echo ""
echo "[lcore-client] Done."
echo "  Client:        ${CLIENT_ID} (${CLIENT_UUID})"
echo "  Audience:      ${OIDC_AUDIENCE}"
echo "  SA subject:    ${SA_SUBJECT:-<unavailable>}"
echo "  Env file:      ${ENV_FILE}"
echo "  K8s secret:    ${TARGET_NAMESPACE}/${OIDC_SECRET_NAME}"
echo ""
echo "  Local run:     set -a; . ${ENV_FILE}; set +a; then run lightspeed-stack"
echo "                 (remember GATEWAY_URL needs the :443 port for gRPC, and"
echo "                  point openshell_tls_ca at the gateway's self-signed CA)."
echo "  In-cluster:    make ocp-prod-lightspeed-apply   # picks up the secret"
