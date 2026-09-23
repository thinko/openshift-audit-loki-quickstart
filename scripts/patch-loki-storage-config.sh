#!/usr/bin/env bash
# Rewrite Azure storage settings inside the live logging-loki-config ConfigMap.
#
# The Loki operator generates that ConfigMap while the stack is Managed, with
# account_name/account_key left as ${AZURE_...} references. Service principal
# auth needs literal values in common.storage.azure (and any other azure block
# that carries account_name or account_key). This script keeps every other
# key the operator wrote and only replaces those storage blocks.
#
# IMPORTANT: If ArgoCD manages the LokiStack on this cluster, you MUST set
# management_state to Unmanaged in the gitops-secrets BEFORE running this
# script, then sync. Otherwise ArgoCD self-heal will revert the LokiStack
# to Managed within minutes, the operator will regenerate the ConfigMap, and
# the SP auth patch will be lost.
#
#   Order of operations (GitOps clusters):
#     1. Set management_state=Unmanaged in Vault / gitops-secrets
#     2. Sync (or wait for ArgoCD self-heal to pick up the new value)
#     3. Run this script
#
# Run it again after a Managed reconcile has regenerated the ConfigMap.
# It switches the LokiStack to Unmanaged first so the operator does not
# overwrite the patched ConfigMap on the next reconcile.
#
# Prerequisites: oc logged in as cluster-admin, yq v4, and:
#   AZURE_STORAGE_ACCOUNT_NAME, AZURE_SP_CLIENT_ID,
#   AZURE_SP_CLIENT_SECRET, AZURE_SP_TENANT_ID
#   AZURE_CONTAINER_NAME or ARO_CLUSTER_NAME / CLUSTER
#   AZURE_ENVIRONMENT (default AzureGlobal)
#
#   scripts/patch-loki-storage-config.sh
#   scripts/patch-loki-storage-config.sh --no-restart
#   scripts/patch-loki-storage-config.sh --render < config.yaml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Every azure map that is a storage credential block. Other azure maps are left alone.
LOKI_AZURE_PATCH_EXPR='
(.. | select(
  type == "!!map"
  and (.azure | type) == "!!map"
  and (
    (.azure | has("account_name"))
    or (.azure | has("account_key"))
    or (.azure | has("use_service_principal"))
  )
) | .azure) |= (
  .environment = strenv(AZURE_ENVIRONMENT) |
  .container_name = strenv(AZURE_CONTAINER_NAME) |
  .account_name = strenv(AZURE_STORAGE_ACCOUNT_NAME) |
  .use_service_principal = true |
  .client_id = strenv(AZURE_SP_CLIENT_ID) |
  .client_secret = strenv(AZURE_SP_CLIENT_SECRET) |
  .tenant_id = strenv(AZURE_SP_TENANT_ID) |
  del(.account_key)
)
'

LOKI_AZURE_COUNT_EXPR='
[.. | select(
  type == "!!map"
  and (.azure | type) == "!!map"
  and (
    (.azure | has("account_name"))
    or (.azure | has("account_key"))
    or (.azure | has("use_service_principal"))
  )
)] | length
'

require_sp_env() {
  AZURE_STORAGE_ACCOUNT_NAME="${AZURE_STORAGE_ACCOUNT_NAME:-}"
  AZURE_CONTAINER_NAME="$(azure_blob_container_name)" || die "Set AZURE_CONTAINER_NAME or ARO_CLUSTER_NAME. Default container is {cluster}-audit-loki."
  AZURE_ENVIRONMENT="${AZURE_ENVIRONMENT:-AzureGlobal}"
  AZURE_SP_CLIENT_ID="${AZURE_SP_CLIENT_ID:-}"
  AZURE_SP_CLIENT_SECRET="${AZURE_SP_CLIENT_SECRET:-}"
  AZURE_SP_TENANT_ID="${AZURE_SP_TENANT_ID:-}"
  export AZURE_STORAGE_ACCOUNT_NAME AZURE_CONTAINER_NAME AZURE_ENVIRONMENT
  export AZURE_SP_CLIENT_ID AZURE_SP_CLIENT_SECRET AZURE_SP_TENANT_ID
  local var
  for var in AZURE_STORAGE_ACCOUNT_NAME AZURE_SP_CLIENT_ID AZURE_SP_CLIENT_SECRET AZURE_SP_TENANT_ID; do
    if [[ -z "${!var}" ]]; then
      die "${var} is not set. Source scripts/load-cluster-env.sh and run load_cluster_env first."
    fi
  done
}

count_azure_blocks() {
  yq eval "${LOKI_AZURE_COUNT_EXPR}" -
}

patch_azure_blocks() {
  yq eval "${LOKI_AZURE_PATCH_EXPR}" -
}

restart_loki_pods() {
  local kind name
  for kind in statefulset deployment; do
    oc get "${kind}" -n "${NAMESPACE}" \
      -l app.kubernetes.io/instance="${LOKISTACK_NAME}" \
      --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | while read -r name; do
        [[ -n "${name}" ]] || continue
        log "  Restarting ${kind}/${name}"
        oc rollout restart "${kind}/${name}" -n "${NAMESPACE}"
      done
  done
}

RESTART=1
RENDER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart) RESTART=0; shift ;;
    --render) RENDER=1; shift ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd yq
require_sp_env

if [[ "${RENDER}" -eq 1 ]]; then
  cfg="$(cat)"
  blocks="$(printf '%s\n' "${cfg}" | count_azure_blocks)"
  [[ "${blocks}" != "0" ]] || die "No azure storage block found in the Loki config."
  printf '%s\n' "${cfg}" | patch_azure_blocks
  exit 0
fi

require_oc
require_cluster_admin

# Guard: if ArgoCD manages this LokiStack with self-heal, the gitops source
# must already render Unmanaged. Otherwise the operator will regenerate the
# ConfigMap within minutes of this script finishing.
check_argocd_selfheal() {
  local app_json desired_state
  # Find the ArgoCD Application targeting openshift-logging (if any)
  app_json="$(oc get applications.argoproj.io -A -o json 2>/dev/null \
    | jq -r '[.items[] | select(.spec.destination.namespace=="openshift-logging")] | first // empty' 2>/dev/null)" || true
  if [[ -z "${app_json}" ]]; then
    return 0  # no ArgoCD app found — manual cluster, safe to proceed
  fi
  local self_heal
  self_heal="$(printf '%s' "${app_json}" | jq -r '.spec.syncPolicy.automated.selfHeal // false')"
  if [[ "${self_heal}" != "true" ]]; then
    return 0  # self-heal off — manual patch will stick
  fi
  # Self-heal is on. Check if the gitops-secrets already says Unmanaged.
  desired_state="$(oc get secret gitops-secrets -n openshift-gitops \
    -o jsonpath='{.data.secrets\.yaml}' 2>/dev/null \
    | base64 -d 2>/dev/null \
    | grep 'management_state' \
    | head -1 \
    | sed 's/.*management_state:[[:space:]]*//' \
    | tr -d '"' \
    | tr -d "'" || true)"
  if [[ "${desired_state}" == "Unmanaged" ]]; then
    log "ArgoCD self-heal is enabled and gitops-secrets has management_state: Unmanaged — safe to proceed"
    return 0
  fi
  err "ArgoCD self-heal is ENABLED for this namespace and gitops-secrets"
  err "has management_state: ${desired_state:-Managed} (not Unmanaged)."
  err ""
  err "If you patch now, ArgoCD will revert the LokiStack to Managed within"
  err "minutes and the operator will overwrite logging-loki-config."
  err ""
  err "Fix first:"
  err "  1. Set management_state=Unmanaged in Vault for this cluster"
  err "  2. Patch gitops-secrets:  oc get secret gitops-secrets -n openshift-gitops -o json \\"
  err "       | jq '.data[\"secrets.yaml\"] |= (@base64d | gsub(\"management_state: .*\"; \"management_state: Unmanaged\") | @base64)' \\"
  err "       | oc apply -f -"
  err "  3. Sync the logging app in the ArgoCD UI"
  err "  4. Re-run this script"
  err ""
  read -rp "Continue anyway? (y/N) " answer
  [[ "${answer}" =~ ^[Yy] ]] || die "Aborted. Fix gitops-secrets first."
}
check_argocd_selfheal

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

if ! oc get configmap logging-loki-config -n "${NAMESPACE}" -o yaml >"${tmp}" 2>/dev/null; then
  die "ConfigMap logging-loki-config not found in ${NAMESPACE}.
The operator writes it during a Managed reconcile. Let that finish, then re-run."
fi

cfg="$(yq eval '.data."config.yaml" | from_yaml' "${tmp}")"
blocks="$(printf '%s\n' "${cfg}" | count_azure_blocks)"
[[ "${blocks}" != "0" && "${blocks}" != "null" ]] || die "logging-loki-config has no azure storage block to patch."

log "Patching ${blocks} azure storage block(s) in logging-loki-config"
LOKI_PATCHED_CONFIG="$(printf '%s\n' "${cfg}" | patch_azure_blocks)"
export LOKI_PATCHED_CONFIG
yq eval -i '.data."config.yaml" = strenv(LOKI_PATCHED_CONFIG)' "${tmp}"
unset LOKI_PATCHED_CONFIG

log "Setting LokiStack managementState to Unmanaged so the operator does not rewrite this ConfigMap"
oc patch lokistack "${LOKISTACK_NAME}" -n "${NAMESPACE}" \
  --type merge -p '{"spec":{"managementState":"Unmanaged"}}'

oc apply -f "${tmp}" >/dev/null
log "Applied logging-loki-config with literal service principal storage settings"

if [[ "${RESTART}" -eq 1 ]]; then
  log "Restarting Loki pods to load the patched config"
  restart_loki_pods
fi
