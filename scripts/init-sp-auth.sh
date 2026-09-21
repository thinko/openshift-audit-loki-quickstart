#!/usr/bin/env bash
# Bootstrap service principal (SP) auth for Loki on clusters where
# AllowSharedKeyAccess=false and Workload Identity Federation is unavailable.
#
# This script:
#   1. Verifies the LokiStack has been reconciled (Managed) at least once
#   2. Creates/updates the logging-loki-azure secret with SP credentials
#   3. Rewrites azure storage blocks in the live logging-loki-config ConfigMap
#      and switches LokiStack managementState to Unmanaged
#   4. Restarts Loki pods to pick up the new config
#
# The operator regenerates logging-loki-config whenever the stack is Managed.
# scripts/patch-loki-storage-config.sh can be run again after that to put the
# service principal values back without replacing the rest of the config.
#
# Prerequisites:
#   - oc logged in as cluster-admin
#   - LokiStack CR applied and operator has reconciled (created StatefulSets etc.)
#   - Environment variables set (via .env or export):
#       AZURE_STORAGE_ACCOUNT_NAME  (required)
#       AZURE_CONTAINER_NAME        (default: {ARO_CLUSTER_NAME}-audit-loki)
#       AZURE_ENVIRONMENT           (default: AzureGlobal)
#       AZURE_SP_CLIENT_ID          (required)
#       AZURE_SP_CLIENT_SECRET      (required)
#       AZURE_SP_TENANT_ID          (required)
#
# Revert path (when shared key exception is granted):
#   1. Create secret with account_key instead of SP creds
#   2. Patch LokiStack: managementState=Managed
#   3. Delete the SP config overlay ConfigMap (ArgoCD will sync)
#   4. The operator takes over and regenerates its own ConfigMap
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_oc
require_cluster_admin

# ── Validate required env vars ──
AZURE_STORAGE_ACCOUNT_NAME="${AZURE_STORAGE_ACCOUNT_NAME:-}"
AZURE_CONTAINER_NAME="$(azure_blob_container_name)" || die "Set AZURE_CONTAINER_NAME or ARO_CLUSTER_NAME. Default container is {cluster}-audit-loki."
AZURE_ENVIRONMENT="${AZURE_ENVIRONMENT:-AzureGlobal}"
AZURE_SP_CLIENT_ID="${AZURE_SP_CLIENT_ID:-}"
AZURE_SP_CLIENT_SECRET="${AZURE_SP_CLIENT_SECRET:-}"
AZURE_SP_TENANT_ID="${AZURE_SP_TENANT_ID:-}"

for var in AZURE_STORAGE_ACCOUNT_NAME AZURE_SP_CLIENT_ID AZURE_SP_CLIENT_SECRET AZURE_SP_TENANT_ID; do
  if [[ -z "${!var}" ]]; then
    die "${var} is not set. Set it in .env or export it."
  fi
done

header "Service Principal Auth Bootstrap"

# ── Step 1: Verify LokiStack exists ──
log "Checking LokiStack/${LOKISTACK_NAME} exists in ${NAMESPACE}"
if ! oc get lokistack "${LOKISTACK_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  die "LokiStack ${LOKISTACK_NAME} not found in ${NAMESPACE}.
The operator must have reconciled the LokiStack at least once before
switching to SP auth. Run ArgoCD sync first."
fi

# Check that the operator has created resources (StatefulSets exist)
SS_COUNT="$(oc get statefulset -n "${NAMESPACE}" -l app.kubernetes.io/instance="${LOKISTACK_NAME}" --no-headers 2>/dev/null | wc -l)"
SS_COUNT="${SS_COUNT##* }"
if (( SS_COUNT == 0 )); then
  die "No StatefulSets found for LokiStack ${LOKISTACK_NAME}.
The operator must reconcile at least once before switching to Unmanaged.
Check: oc get statefulset -n ${NAMESPACE}"
fi
log "Found ${SS_COUNT} StatefulSet(s) for LokiStack ${LOKISTACK_NAME}"

# ── Step 2: Create/update Azure secret with SP credentials ──
log "Creating/updating secret ${SECRET_NAME} with SP credentials"
# --from-literal stores this string as the secret value. The operator
# base64-decodes it and rejects a single encoding ("not valid base64"),
# which blocks creation of the Loki components. Two layers pass the check.
# A real Azure account key is already one layer; do not double-encode it.
DUMMY_ACCOUNT_KEY="$(printf 'unused' | base64 | tr -d '\n' | base64 | tr -d '\n')"
oc create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal=environment="${AZURE_ENVIRONMENT}" \
  --from-literal=account_name="${AZURE_STORAGE_ACCOUNT_NAME}" \
  --from-literal=container="${AZURE_CONTAINER_NAME}" \
  --from-literal=client_id="${AZURE_SP_CLIENT_ID}" \
  --from-literal=client_secret="${AZURE_SP_CLIENT_SECRET}" \
  --from-literal=tenant_id="${AZURE_SP_TENANT_ID}" \
  --from-literal=account_key="${DUMMY_ACCOUNT_KEY}" \
  --dry-run=client -o yaml | oc apply -f -

# ── Step 3: Patch the live ConfigMap and switch to Unmanaged ──
# patch-loki-storage-config.sh reads the operator-generated ConfigMap,
# replaces only the azure storage blocks, and sets managementState Unmanaged.
log "Patching azure storage blocks in the live logging-loki-config ConfigMap"
"${SCRIPT_DIR}/patch-loki-storage-config.sh" --no-restart

# ── Step 4: Restart Loki pods ──
log "Restarting Loki pods to pick up new config"
for kind in statefulset deployment; do
  oc get "${kind}" -n "${NAMESPACE}" \
    -l app.kubernetes.io/instance="${LOKISTACK_NAME}" \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
  | while read -r name; do
      log "  Restarting ${kind}/${name}"
      oc rollout restart "${kind}/${name}" -n "${NAMESPACE}"
    done
done

header "SP Auth Bootstrap Complete"
echo ""
echo "LokiStack is now in Unmanaged mode with SP auth."
echo "The operator will NOT reconcile Loki components."
echo ""
echo "Monitor pod startup:"
echo "  oc get pods -n ${NAMESPACE} -l app.kubernetes.io/instance=${LOKISTACK_NAME} -w"
echo ""
echo "To revert to standard auth (when shared key exception is approved):"
echo "  1. Recreate secret with account_key"
echo "  2. oc patch lokistack ${LOKISTACK_NAME} -n ${NAMESPACE} --type merge -p '{\"spec\":{\"managementState\":\"Managed\"}}'"
echo "  3. Delete the SP config overlay from gitops (ArgoCD will sync)"
