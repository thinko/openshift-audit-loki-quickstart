#!/usr/bin/env bash
# Bootstrap service principal (SP) auth for Loki on clusters where
# AllowSharedKeyAccess=false and Workload Identity Federation is unavailable.
#
# This script:
#   1. Verifies the LokiStack has been reconciled (Managed) at least once
#   2. Creates/updates the logging-loki-azure secret with SP credentials
#   3. Switches LokiStack managementState to Unmanaged
#   4. Applies the SP config overlay ConfigMap
#   5. Restarts Loki pods to pick up the new config
#
# Prerequisites:
#   - oc logged in as cluster-admin
#   - LokiStack CR applied and operator has reconciled (created StatefulSets etc.)
#   - The loki-config-sp-overlay.yaml has been populated with real config
#     (not the placeholder TODO content)
#   - Environment variables set (via .env or export):
#       AZURE_STORAGE_ACCOUNT_NAME  (required)
#       AZURE_CONTAINER_NAME        (default: loki-audit)
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
AZURE_CONTAINER_NAME="${AZURE_CONTAINER_NAME:-loki-audit}"
AZURE_ENVIRONMENT="${AZURE_ENVIRONMENT:-AzureGlobal}"
AZURE_SP_CLIENT_ID="${AZURE_SP_CLIENT_ID:-}"
AZURE_SP_CLIENT_SECRET="${AZURE_SP_CLIENT_SECRET:-}"
AZURE_SP_TENANT_ID="${AZURE_SP_TENANT_ID:-}"

for var in AZURE_STORAGE_ACCOUNT_NAME AZURE_SP_CLIENT_ID AZURE_SP_CLIENT_SECRET AZURE_SP_TENANT_ID; do
  if [[ -z "${!var}" ]]; then
    die "${var} is not set. Set it in .env or export it."
  fi
done

OVERLAY_FILE="${ROOT}/gitops/namespaces/openshift-logging/loki-config-sp-overlay.yaml"
if grep -q 'TODO.*Replace' "${OVERLAY_FILE}" 2>/dev/null; then
  die "loki-config-sp-overlay.yaml still contains TODO placeholders.
Export the real ConfigMap from a running cluster first:
  oc get configmap logging-loki-config -n ${NAMESPACE} -o yaml
Then patch the azure_storage_config sections to add use_service_principal: true."
fi

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
oc create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal=environment="${AZURE_ENVIRONMENT}" \
  --from-literal=account_name="${AZURE_STORAGE_ACCOUNT_NAME}" \
  --from-literal=container="${AZURE_CONTAINER_NAME}" \
  --from-literal=client_id="${AZURE_SP_CLIENT_ID}" \
  --from-literal=client_secret="${AZURE_SP_CLIENT_SECRET}" \
  --from-literal=tenant_id="${AZURE_SP_TENANT_ID}" \
  --from-literal=account_key="placeholder-not-used-with-sp-auth" \
  --dry-run=client -o yaml | oc apply -f -

# ── Step 3: Switch to Unmanaged ──
log "Setting LokiStack managementState to Unmanaged"
oc patch lokistack "${LOKISTACK_NAME}" -n "${NAMESPACE}" \
  --type merge -p '{"spec":{"managementState":"Unmanaged"}}'

# ── Step 4: Apply SP config overlay ──
log "Applying SP config overlay ConfigMap"
oc apply -f "${OVERLAY_FILE}"

# ── Step 5: Restart Loki pods ──
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
