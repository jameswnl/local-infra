#!/usr/bin/env bash
# Reproduces (or rules out) the OCP kubernetes-driver EACCES-on-COPY'd-content
# bug documented in
# ~/ws/lightspeed-stack/docs/design/cloud-agents/prod/ocp-sandbox-file-read-eacces.md
#
# That doc found: on a real OpenShift cluster, any file added to a sandbox
# image in a layer *after* its base image is unreadable to the sandbox's own
# process (open() -> EACCES), while base-image content reads fine. Checking
# only file existence/executable-bit (e.g. `command -v`, `which`) does NOT
# exercise this -- those are stat()/access() checks, not open()+read(). This
# script does the real thing: cat's a later-layer file and executes one.
#
# Usage:
#   ./ocp/test-eacces-repro.sh <gateway-name> <namespace> [image] [control-file] [layer-file] [exec-pythonpath] [exec-module]
#
# <gateway-name> must already be registered (make ocp-register / ocp-prod-register).
# Requires: openshell CLI, oc.
#
# The execute check imports a real Python module from a later-layer source
# directory rather than invoking a prebuilt binary. Earlier iterations of
# this script used `claude --version`, but that command is a known-broken
# npm placeholder stub in this image (postinstall never fetched the native
# binary for this platform) that always fails with "Exec format error"
# regardless of the platform bug this script tests for -- a plain text file
# with no shebang, not an EACCES/permissions issue. An `import` forces the
# interpreter to actually open(), read(), and execute the module's source,
# which is what the doc's "sandbox's own agent code... can never be read or
# executed" concern is really about.
set -euo pipefail

GATEWAY="${1:?usage: $0 <gateway-name> <namespace> [image] [control-file] [layer-file] [exec-pythonpath] [exec-module]}"
NAMESPACE="${2:?usage: $0 <gateway-name> <namespace> [image] [control-file] [layer-file] [exec-pythonpath] [exec-module]}"
IMAGE="${3:-quay.io/jameswong/lightspeed-agentic-sandbox:latest-amd64}"
CONTROL_FILE="${4:-/etc/os-release}"
LAYER_FILE="${5:-/opt/lightspeed/pyproject.toml}"
EXEC_PYTHONPATH="${6:-/opt/lightspeed/src:/opt/app-root/lib64/python3.12/site-packages}"
EXEC_MODULE="${7:-lightspeed_agentic}"

SANDBOX_NAME="eacces-repro-$$"
POD="default--${SANDBOX_NAME}"

# --gateway-insecure is a no-op against a plaintext (eval) gateway and
# required against the production gateway's self-signed cert -- passing it
# unconditionally lets this script work against either without a flag.
OPENSHELL=(openshell -g "${GATEWAY}" --gateway-insecure)

cleanup() {
  "${OPENSHELL[@]}" sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Creating sandbox '${SANDBOX_NAME}' from ${IMAGE} on gateway '${GATEWAY}'..."
"${OPENSHELL[@]}" sandbox create --name "${SANDBOX_NAME}" --from "${IMAGE}"

echo "Waiting for pod ${POD} in namespace ${NAMESPACE}..."
oc -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD}" --timeout=120s

check() {
  local label="$1"
  shift
  local err
  if err=$(oc -n "${NAMESPACE}" exec "${POD}" -- "$@" 2>&1 >/dev/null); then
    echo "[PASS] ${label}"
  else
    echo "[FAIL] ${label} -- ${err}"
  fi
}

echo ""
echo "=== Control: read a base-image file (expect PASS) ==="
check "read ${CONTROL_FILE}" cat "${CONTROL_FILE}"

echo ""
echo "=== Repro 1: read a file COPY'd in a later build layer ==="
check "read ${LAYER_FILE}" cat "${LAYER_FILE}"

echo ""
echo "=== Repro 2: execute (not just stat) later-layer source via python import ==="
check "PYTHONPATH=${EXEC_PYTHONPATH} python3.12 -c 'import ${EXEC_MODULE}'" \
  env PYTHONPATH="${EXEC_PYTHONPATH}" python3.12 -c "import ${EXEC_MODULE}"

echo ""
echo "If either 'Repro' check FAILs with Permission denied while the Control"
echo "check PASSes, this reproduces the bug in"
echo "~/ws/lightspeed-stack/docs/design/cloud-agents/prod/ocp-sandbox-file-read-eacces.md"
echo "If both PASS, this cluster/image combination does not exhibit it."
