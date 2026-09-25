#!/usr/bin/env bash
# Enable Azure Service Principal authentication for Loki on clusters where
# AllowSharedKeyAccess is disabled.
#
# The Loki Operator generates logging-loki-config with account_key references.
# SP auth approach depends on the operator-generated config structure:
#
#   Direct layout (operator ≤ v6.5.2):
#     Config has common.storage.azure (BlobStorageConfig type) which accepts
#     SP auth fields directly. The script patches the ConfigMap with literal
#     SP values and removes account_key.
#
#   Object-store layout (operator ≥ v6.5.3, ALL sizes):
#     Config has common.storage.object_store.azure (azure.Config type) which
#     does NOT support SP auth fields. Instead, the script:
#       - Removes account_key from the ConfigMap
#       - Injects AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID as
#         env vars on all Loki StatefulSets/Deployments
#       - Removes AZURE_STORAGE_ACCOUNT_KEY env var from all workloads
#     The Azure SDK DefaultAzureCredential picks up the env vars automatically.
#
#   The layout is auto-detected from the live ConfigMap regardless of size.
#
# IMPORTANT: If ArgoCD manages the LokiStack on this cluster, you MUST set
# management_state to Unmanaged in the gitops-secrets BEFORE running this
# script, then sync. Otherwise ArgoCD self-heal will revert the LokiStack
# to Managed within minutes, the operator will regenerate the ConfigMap, and
# the SP auth patch will be lost.
#
#   Order of operations (GitOps clusters):
#     1. Set management_state=Unmanaged in Vault for this cluster
#     2. Patch gitops-secrets to match (the Conjur sidecar caches secrets.yaml
#        at pod startup — patching the Secret directly is the fastest path)
#     3. Restart openshift-gitops-repo-server so the Conjur CMP sidecar
#        re-reads the updated gitops-secrets:
#          oc rollout restart deployment/openshift-gitops-repo-server -n openshift-gitops
#          oc rollout status  deployment/openshift-gitops-repo-server -n openshift-gitops --timeout=120s
#     4. Hard Refresh the logging app in ArgoCD (not just Refresh — forces
#        a re-render through the ytt/Conjur sidecar)
#     5. Sync the logging app and verify live managementState=Unmanaged:
#          oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.spec.managementState}'
#     6. Run this script
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

# ── yq expressions for direct layout (ConfigMap patching) ──────────

# Patch every azure block that carries storage credentials
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

# ── yq expression for object-store layout (strip account_key only) ─

LOKI_STRIP_ACCOUNT_KEY_EXPR='
(.. | select(
  type == "!!map"
  and (.azure | type) == "!!map"
  and (.azure | has("account_key"))
) | .azure) |= del(.account_key)
'

# ── Environment validation ─────────────────────────────────────────

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

# ── Helpers ────────────────────────────────────────────────────────

count_azure_blocks() {
  yq eval "${LOKI_AZURE_COUNT_EXPR}" -
}

patch_azure_blocks() {
  yq eval "${LOKI_AZURE_PATCH_EXPR}" -
}

strip_account_key_from_config() {
  yq eval "${LOKI_STRIP_ACCOUNT_KEY_EXPR}" -
}

# Detect whether the config uses object_store wrapper (v6.5.3+) or direct azure (v6.5.2-)
detect_config_layout() {
  local cfg="$1"
  if printf '%s\n' "${cfg}" | yq eval '.common.storage | has("object_store")' - 2>/dev/null | grep -q 'true'; then
    echo "object_store"
  else
    echo "direct"
  fi
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

# Inject SP env vars and remove the shared key env var from all Loki workloads
inject_sp_env_vars() {
  local kind name count=0
  for kind in statefulset deployment; do
    oc get "${kind}" -n "${NAMESPACE}" \
      -l app.kubernetes.io/instance="${LOKISTACK_NAME}" \
      --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | while read -r name; do
        [[ -n "${name}" ]] || continue
        log "  Injecting SP env vars on ${kind}/${name}"
        oc set env "${kind}/${name}" -n "${NAMESPACE}" \
          AZURE_CLIENT_ID="${AZURE_SP_CLIENT_ID}" \
          AZURE_CLIENT_SECRET="${AZURE_SP_CLIENT_SECRET}" \
          AZURE_TENANT_ID="${AZURE_SP_TENANT_ID}" \
          AZURE_STORAGE_ACCOUNT_KEY-
        count=$((count + 1))
      done
  done
  log "Injected SP env vars on ${count} workloads"
}

# ── ArgoCD self-heal guard ─────────────────────────────────────────

check_argocd_selfheal() {
  local app_json desired_state
  app_json="$(oc get applications.argoproj.io -A -o json 2>/dev/null \
    | jq -r '[.items[] | select(.spec.destination.namespace=="openshift-logging")] | first // empty' 2>/dev/null)" || true
  if [[ -z "${app_json}" ]]; then
    return 0
  fi
  local self_heal
  self_heal="$(printf '%s' "${app_json}" | jq -r '.spec.syncPolicy.automated.selfHeal // false')"
  if [[ "${self_heal}" != "true" ]]; then
    return 0
  fi
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

# ── CLI ────────────────────────────────────────────────────────────

RESTART=1
RENDER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart) RESTART=0; shift ;;
    --render) RENDER=1; shift ;;
    -h|--help)
      sed -n '2,50p' "$0"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd yq
require_sp_env

# ── --render mode: stdin → stdout, no cluster access needed ────────

if [[ "${RENDER}" -eq 1 ]]; then
  cfg="$(cat)"
  blocks="$(printf '%s\n' "${cfg}" | count_azure_blocks)"
  [[ "${blocks}" != "0" ]] || die "No azure storage block found in the Loki config."
  printf '%s\n' "${cfg}" | patch_azure_blocks
  exit 0
fi

# ── Live cluster mode ──────────────────────────────────────────────

require_oc
require_cluster_admin
check_argocd_selfheal

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

if ! oc get configmap logging-loki-config -n "${NAMESPACE}" -o yaml >"${tmp}" 2>/dev/null; then
  die "ConfigMap logging-loki-config not found in ${NAMESPACE}.
The operator writes it during a Managed reconcile. Let that finish, then re-run."
fi

cfg="$(yq eval '.data."config.yaml" | from_yaml' "${tmp}")"
layout="$(detect_config_layout "${cfg}")"
log "Detected LokiStack config layout: ${layout}"

log "Setting LokiStack managementState to Unmanaged so the operator does not rewrite this ConfigMap"
oc patch lokistack "${LOKISTACK_NAME}" -n "${NAMESPACE}" \
  --type merge -p '{"spec":{"managementState":"Unmanaged"}}'

if [[ "${layout}" == "direct" ]]; then
  # ── Direct layout (v6.5.2-): patch ConfigMap with literal SP values ──
  blocks="$(printf '%s\n' "${cfg}" | count_azure_blocks)"
  [[ "${blocks}" != "0" && "${blocks}" != "null" ]] || die "logging-loki-config has no azure storage block to patch."

  log "Patching ${blocks} azure storage block(s) in logging-loki-config (direct layout, operator ≤v6.5.2)"
  LOKI_PATCHED_CONFIG="$(printf '%s\n' "${cfg}" | patch_azure_blocks)"
  export LOKI_PATCHED_CONFIG
  yq eval -i '.data."config.yaml" = strenv(LOKI_PATCHED_CONFIG)' "${tmp}"
  unset LOKI_PATCHED_CONFIG

  oc apply -f "${tmp}" >/dev/null
  log "Applied logging-loki-config with literal service principal storage settings"

else
  # ── Object-store layout (v6.5.3+): strip account_key from ConfigMap + inject env vars ──
  log "Stripping account_key from logging-loki-config (object_store layout, operator ≥v6.5.3)"
  LOKI_PATCHED_CONFIG="$(printf '%s\n' "${cfg}" | strip_account_key_from_config)"
  export LOKI_PATCHED_CONFIG
  yq eval -i '.data."config.yaml" = strenv(LOKI_PATCHED_CONFIG)' "${tmp}"
  unset LOKI_PATCHED_CONFIG

  oc apply -f "${tmp}" >/dev/null
  log "Applied logging-loki-config with account_key removed"

  log "Injecting Azure SP env vars on all Loki workloads and removing AZURE_STORAGE_ACCOUNT_KEY"
  inject_sp_env_vars
  log "Azure SDK DefaultAzureCredential will pick up AZURE_CLIENT_ID/SECRET/TENANT_ID from env vars"
fi

if [[ "${RESTART}" -eq 1 && "${layout}" == "direct" ]]; then
  log "Restarting Loki pods to load the patched config"
  restart_loki_pods
elif [[ "${layout}" == "object_store" ]]; then
  log "Pods will restart automatically from the env var changes"
fi

log "Done. Verify with:"
log "  oc get pods -n ${NAMESPACE} -l app.kubernetes.io/instance=${LOKISTACK_NAME}"
log "  oc logs <ingester-pod> -n ${NAMESPACE} -c loki-ingester --tail=20"
