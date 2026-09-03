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
#   WORKSPACE_ROLE          admin            (role to grant; the stack's
#                                             provider-profile setup
#                                             (ImportProviderProfiles) requires
#                                             'admin', not 'user')
#   GATEWAY_NAME            ocp-prod         (openshell CLI gateway name used
#                                             to add the workspace member)
#   GATEWAY_INSECURE        true             (pass --gateway-insecure to the
#                                             CLI; the gateway's self-signed
#                                             CA isn't in the CLI's trust store)
#   SERVER_TLS_SECRET       <release>-server-external-tls
#                                             (secret holding the gateway's
#                                             external-route CA to extract)
#   TLS_CA_FILE             ~/.config/openshell/gateways/<gw>/ca.crt
#                                             (where to write the extracted CA;
#                                             recorded as OPENSHELL_TLS_CA)
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
WORKSPACE_ROLE="${WORKSPACE_ROLE:-admin}"
GATEWAY_NAME="${GATEWAY_NAME:-ocp-prod}"
GATEWAY_INSECURE="${GATEWAY_INSECURE:-true}"
OPENSHELL_CLI="${OPENSHELL_CLI:-openshell}"
# The gateway's external-route TLS secret and where to drop its self-signed CA
# so the stack (openshell_tls_ca) can verify the gRPC connection. certifi
# can't -- the CA is self-signed. Written into ENV_FILE as OPENSHELL_TLS_CA.
SERVER_TLS_SECRET="${SERVER_TLS_SECRET:-${OCP_PROD_RELEASE:-openshell-prod}-server-external-tls}"
TLS_CA_FILE="${TLS_CA_FILE:-${HOME}/.config/openshell/gateways/${GATEWAY_NAME}/ca.crt}"

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
# `|| true`: with `set -o pipefail`, a grep-no-match (e.g. service-account
# user not yet present) would otherwise kill the script via `set -e` before
# reaching the empty-check warning below.
SA_SUBJECT="$(kc get "clients/${CLIENT_UUID}/service-account-user" -r "${REALM}" 2>/dev/null \
  | tr -d '\r' | grep -o '"id"[^,}]*' | sed 's/.*: *"\(.*\)".*/\1/' | head -n1 || true)"
if [ -z "${SA_SUBJECT}" ]; then
  echo "warning: could not read the service-account user id -- leaving SA_SUBJECT empty." >&2
fi

# Ensure the written gateway URL carries an explicit gRPC port so it's
# directly usable by lightspeed-stack. The Makefile passes https://<host>
# (no port), but the stack's spawner strips the scheme and uses the remainder
# verbatim as a gRPC endpoint, which needs a port. The OCP Route serves gRPC
# over TLS on 443. Skip if a port is already present (idempotent).
gateway_hostport="${GATEWAY_URL#*://}"
case "${gateway_hostport}" in
  *:*) ;;                              # already has a :port -- leave as-is
  *) GATEWAY_URL="${GATEWAY_URL}:443" ;;
esac

# Extract the gateway's external-route self-signed CA so the stack can verify
# the gRPC connection (openshell_tls_ca). Written to TLS_CA_FILE and recorded
# as OPENSHELL_TLS_CA in ENV_FILE, so sourcing ENV_FILE is all a local run
# needs -- no manual `oc extract` / export. Non-fatal if the secret is absent.
TLS_CA_ENV=""
echo "[lcore-client] Extracting gateway CA from ${TARGET_NAMESPACE}/${SERVER_TLS_SECRET}..."
ca_b64="$(oc -n "${TARGET_NAMESPACE}" get secret "${SERVER_TLS_SECRET}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
if [ -n "${ca_b64}" ]; then
  mkdir -p "$(dirname "${TLS_CA_FILE}")"
  printf '%s' "${ca_b64}" | base64 -d > "${TLS_CA_FILE}"
  TLS_CA_ENV="${TLS_CA_FILE}"
  echo "[lcore-client] Wrote gateway CA to ${TLS_CA_FILE}."
else
  echo "warning: secret ${TARGET_NAMESPACE}/${SERVER_TLS_SECRET} has no ca.crt --" >&2
  echo "         OPENSHELL_TLS_CA left empty; set it manually or the stack's TLS" >&2
  echo "         handshake to the gateway will fail (self-signed CA)." >&2
fi

echo "[lcore-client] Writing ${ENV_FILE}..."
printf 'OPENSHELL_OIDC_CLIENT_SECRET=%s\nOPENSHELL_OIDC_CLIENT_ID=%s\nOPENSHELL_OIDC_ISSUER=%s\nOPENSHELL_OIDC_AUDIENCE=%s\nOPENSHELL_GATEWAY_URL=%s\nOPENSHELL_TLS_CA=%s\nOPENSHELL_SA_SUBJECT=%s\n' \
  "${CLIENT_SECRET}" "${CLIENT_ID}" "${OIDC_ISSUER}" "${OIDC_AUDIENCE}" "${GATEWAY_URL}" "${TLS_CA_ENV}" "${SA_SUBJECT}" > "${ENV_FILE}"

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
# grant membership to here. The role must be 'admin': the stack's provider-
# profile setup (ImportProviderProfiles, run on every ephemeral spawn) requires
# workspace-admin, not merely 'user'. Uses the openshell CLI (already logged in
# as an admin by `make ocp-prod-register`); --gateway-insecure because the
# gateway's self-signed CA isn't in the CLI's trust store.
#
# `member add` won't upgrade an existing member's role ("member already
# exists"), so reconcile: if the subject is present with the wrong role, remove
# and re-add; if absent, add; if already correct, leave it.
if [ -n "${SKIP_WORKSPACE_MEMBER:-}" ]; then
  echo "[lcore-client] SKIP_WORKSPACE_MEMBER set -- skipping workspace membership grant."
elif [ -z "${SA_SUBJECT}" ]; then
  echo "warning: SA subject unknown -- cannot grant workspace membership. The stack" >&2
  echo "         will get PERMISSION_DENIED until you add it manually." >&2
elif ! command -v "${OPENSHELL_CLI}" >/dev/null 2>&1; then
  echo "warning: '${OPENSHELL_CLI}' CLI not found -- skipping workspace membership grant." >&2
  echo "         Grant it manually, then the stack can spawn:" >&2
  echo "         ${OPENSHELL_CLI} workspace member add --workspace ${WORKSPACE} --subject ${SA_SUBJECT} --role ${WORKSPACE_ROLE}" >&2
else
  insecure_flag=""
  if [ "${GATEWAY_INSECURE}" = "true" ]; then insecure_flag="--gateway-insecure"; fi
  echo "[lcore-client] Ensuring service account ${SA_SUBJECT} is an '${WORKSPACE_ROLE}' of workspace '${WORKSPACE}'..."
  # Grab the current role from the member list row ("<subject>  <role>"), if any.
  # `|| true` below: with `set -o pipefail`, grep finding no row (the normal
  # first-run case: subject not yet a member) would otherwise kill the script
  # via `set -e` with no diagnostic before the add below.
  current_role="$("${OPENSHELL_CLI}" ${insecure_flag} -g "${GATEWAY_NAME}" workspace member list --workspace "${WORKSPACE}" 2>/dev/null \
    | grep "${SA_SUBJECT}" | awk '{print $NF}' | head -n1 || true)"
  if [ "${current_role}" = "${WORKSPACE_ROLE}" ]; then
    echo "[lcore-client] Already an '${WORKSPACE_ROLE}' of '${WORKSPACE}'."
  else
    if [ -n "${current_role}" ]; then
      echo "[lcore-client] Member exists with role '${current_role}' -- removing to re-grant as '${WORKSPACE_ROLE}'..."
      "${OPENSHELL_CLI}" ${insecure_flag} -g "${GATEWAY_NAME}" workspace member remove \
        --workspace "${WORKSPACE}" --subject "${SA_SUBJECT}"
    fi
    "${OPENSHELL_CLI}" ${insecure_flag} -g "${GATEWAY_NAME}" workspace member add \
      --workspace "${WORKSPACE}" --subject "${SA_SUBJECT}" --role "${WORKSPACE_ROLE}"
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
echo "  Gateway CA:    ${TLS_CA_ENV:-<unavailable>}"
echo "  Local run:     set -a; . ${ENV_FILE}; set +a; then run lightspeed-stack"
echo "                 (GATEWAY_URL carries the :443 gRPC port and OPENSHELL_TLS_CA"
echo "                  is set -- sourcing the env file is all that's needed)."
echo "  In-cluster:    make ocp-prod-lightspeed-apply   # picks up the secret"
