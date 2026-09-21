#!/usr/bin/env bash
# Generate a cluster-specific overlay from Vault (safe CLI).
#
# Reads all loki-storage keys from Vault and produces:
#   1. _overlays/<cluster>/values.yaml   (committed to git)
#   2. _overlays/<cluster>/clusters.yaml  (committed to git)
#   3. _overlays/<cluster>/gitops-secrets-loki-storage.yaml  (NOT committed;
#      content to inject into the gitops-secrets Secret in openshift-gitops)
#
# Usage:
#   scripts/generate-overlay.sh <cluster-name> [--from <sibling-cluster>]
#
# --from copies values that are the same across clusters (image, AD groups,
# storage account, service principal) from that cluster's Vault path.
# It does not copy container, deployment_id, grafana_admin_password, or
# management_state. Those stay specific to the new cluster.
#
# Prerequisites:
#   - `safe` CLI authenticated to the target Vault
#   - `yq` (v4+) for YAML manipulation
#
# Vault path convention:
#   secret/my-team/openshift/<cluster>/loki-storage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────
log()    { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err()    { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()    { err "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# ── Argument parsing ─────────────────────────────────────────────────
CLUSTER=""
SIBLING=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ -n "${2:-}" && "${2}" != --* ]] || die "--from requires a sibling cluster name"
      SIBLING="$2"
      shift 2
      ;;
    --from=*)
      SIBLING="${1#--from=}"
      [[ -n "${SIBLING}" ]] || die "--from requires a sibling cluster name"
      shift
      ;;
    -h|--help)
      die "Usage: $0 <cluster-name> [--from <sibling-cluster>]"
      ;;
    --*)
      die "Unknown option: $1"
      ;;
    *)
      [[ -z "${CLUSTER}" ]] || die "Unexpected argument: $1"
      CLUSTER="$1"
      shift
      ;;
  esac
done
[[ -n "${CLUSTER}" ]] || die "Usage: $0 <cluster-name> [--from <sibling-cluster>]"
[[ "${SIBLING}" != "${CLUSTER}" ]] || die "--from must name a different cluster"

VAULT_BASE="${VAULT_BASE:-secret/my-team/openshift}"
VAULT_PATH="${VAULT_BASE}/${CLUSTER}/loki-storage"
OVERLAY_DIR="${ROOT}/_overlays/${CLUSTER}"
CUSTOMER_BASE="${ROOT}/_overlays/_customer/values-base.yaml"
TEMPLATE_DIR="${ROOT}/_overlays/_template"

need_cmd safe
need_cmd yq

# ── Read keys from Vault ─────────────────────────────────────────────
# safe get outputs key:value pairs; read into an associative array.
read_vault() {
  local path="$1"
  local -n _out="$2"
  while IFS=: read -r key value; do
    [[ -n "${key}" ]] || continue
    value="${value#"${value%%[![:space:]]*}"}"
    _out["${key}"]="${value}"
  done < <(safe get "${path}" 2>/dev/null)
}

declare -A vault=()
declare -A sibling=()
SIBLING_PATH=""
if [[ -n "${SIBLING}" ]]; then
  SIBLING_PATH="${VAULT_BASE}/${SIBLING}/loki-storage"
  log "Reading sibling Vault path: ${SIBLING_PATH}"
  safe exists "${SIBLING_PATH}" 2>/dev/null \
    || die "Sibling Vault path ${SIBLING_PATH} does not exist."
  read_vault "${SIBLING_PATH}" sibling
fi

log "Validating Vault path: ${VAULT_PATH}"
if safe exists "${VAULT_PATH}" 2>/dev/null; then
  log "Reading keys from ${VAULT_PATH}"
  read_vault "${VAULT_PATH}" vault
elif [[ -n "${SIBLING}" ]]; then
  log "Vault path ${VAULT_PATH} does not exist; shared keys come from ${SIBLING}"
else
  die "Vault path ${VAULT_PATH} does not exist.
Create it with the values this script cannot discover:
  safe set ${VAULT_PATH} \\
    account_name=<STORAGE_ACCOUNT> \\
    client_id=<SP_CLIENT_ID> \\
    client_secret=<SP_SECRET> \\
    tenant_id=<TENANT_ID>
Or copy the shared values from a cluster that already has them:
  $0 ${CLUSTER} --from <sibling-cluster>
Leave grafana_admin_password unset. The Grafana PostSync hook generates
a random password when that value is empty.
grafana_image and rbac.edit / rbac.view also come from
_overlays/_customer/values-base.yaml when Vault omits them.
These are filled automatically when omitted: container=${CLUSTER}-audit-loki,
environment=AzureGlobal, lokistack_size=1x.small (quota follows the size),
management_state=Managed, storage_class=managed-csi,
deployment_id=${CLUSTER}-logging. tenant_id is read from 'az account show'
when it is empty and az is logged in."
fi

# Copied from --from when this cluster's key is empty.
# Not copied: container, deployment_id, grafana_admin_password, management_state.
SIBLING_KEYS=(
  account_name account_key environment
  client_id client_secret tenant_id
  grafana_image
  lokistack_size storage_class
  requests_cpu requests_memory limits_memory
  rbac_edit rbac_view
)
if [[ -n "${SIBLING}" ]]; then
  for key in "${SIBLING_KEYS[@]}"; do
    if [[ -z "${vault[${key}]:-}" && -n "${sibling[${key}]:-}" ]]; then
      vault["${key}"]="${sibling[${key}]}"
      log "${key} from sibling ${SIBLING}"
    fi
  done
fi

# ── Fill what Vault did not set ──────────────────────────────────────
CLUSTER_LC="$(printf '%s' "${CLUSTER}" | tr '[:upper:]' '[:lower:]')"

if [[ -z "${vault[account_name]:-}" ]] && command -v az >/dev/null 2>&1 \
  && az account show >/dev/null 2>&1; then
  tagged="$(az resource list --resource-type Microsoft.Storage/storageAccounts \
    --query "[?tags.purpose=='loki-audit'].name" -o tsv)"
  tagged_count="$(printf '%s\n' "${tagged}" | grep -c . || true)"
  if [[ "${tagged_count}" -eq 1 ]]; then
    vault[account_name]="${tagged}"
    log "account_name from the only purpose=loki-audit storage account"
  fi
fi

[[ -n "${vault[account_name]:-}" ]] || die "Vault key 'account_name' is missing at ${VAULT_PATH}.
Pass the storage account name. It cannot be derived from the cluster name
unless this subscription has exactly one account tagged purpose=loki-audit."

V_ACCOUNT_NAME="${vault[account_name]}"
V_ACCOUNT_KEY="${vault[account_key]:-}"
V_CONTAINER="${vault[container]:-${CLUSTER_LC}-audit-loki}"
V_ENVIRONMENT="${vault[environment]:-AzureGlobal}"
V_CLIENT_ID="${vault[client_id]:-}"
V_CLIENT_SECRET="${vault[client_secret]:-}"
V_TENANT_ID="${vault[tenant_id]:-}"
if [[ -z "${V_TENANT_ID}" ]] && command -v az >/dev/null 2>&1 \
  && az account show >/dev/null 2>&1; then
  V_TENANT_ID="$(az account show --query tenantId -o tsv)"
  log "tenant_id from az account show"
fi
# Empty on purpose. grafana-secret.yaml emits nothing, and the PostSync
# hook creates grafana-admin-credentials with a random password.
V_GRAFANA_PASSWORD="${vault[grafana_admin_password]:-}"
if [[ -z "${V_GRAFANA_PASSWORD}" ]]; then
  log "grafana_admin_password left empty; PostSync hook will generate one"
else
  log "grafana_admin_password is set in Vault; PostSync will keep that password"
fi
V_GRAFANA_IMAGE="${vault[grafana_image]:-}"
V_LOKISTACK_SIZE="${vault[lokistack_size]:-1x.small}"
case "${V_LOKISTACK_SIZE}" in
  1x.extra-small) DEF_CPU=30;  DEF_MEM=64Gi;  DEF_LIM=128Gi ;;
  1x.small)       DEF_CPU=72;  DEF_MEM=176Gi; DEF_LIM=256Gi ;;
  1x.medium)      DEF_CPU=100; DEF_MEM=256Gi; DEF_LIM=384Gi ;;
  *) die "Unknown lokistack_size '${V_LOKISTACK_SIZE}'. Use 1x.extra-small, 1x.small, or 1x.medium." ;;
esac
V_MANAGEMENT_STATE="${vault[management_state]:-Managed}"
V_STORAGE_CLASS="${vault[storage_class]:-managed-csi}"
V_REQUESTS_CPU="${vault[requests_cpu]:-${DEF_CPU}}"
V_REQUESTS_MEMORY="${vault[requests_memory]:-${DEF_MEM}}"
V_LIMITS_MEMORY="${vault[limits_memory]:-${DEF_LIM}}"
V_RBAC_EDIT="${vault[rbac_edit]:-}"
V_RBAC_VIEW="${vault[rbac_view]:-}"
V_DEPLOYMENT_ID="${vault[deployment_id]:-${CLUSTER_LC}-logging}"

# Shared image and AD groups live in the customer base. Vault still wins
# when a cluster sets its own value. Empty and TBD are ignored.
# A YAML list is joined into the comma-separated form Vault uses.
customer_shared() {
  local path="$1" kind value
  [[ -f "${CUSTOMER_BASE}" ]] || return 0
  kind="$(yq -r "${path} | type" "${CUSTOMER_BASE}" 2>/dev/null || true)"
  case "${kind}" in
    '!!seq')
      value="$(yq -r "${path} | map(select(. != \"\" and . != \"TBD\")) | join(\",\")" "${CUSTOMER_BASE}")"
      ;;
    '!!str')
      value="$(yq -r "${path}" "${CUSTOMER_BASE}")"
      [[ "${value}" == "TBD" ]] && value=""
      ;;
    *)
      value=""
      ;;
  esac
  printf '%s' "${value}"
}
if [[ -z "${V_GRAFANA_IMAGE}" ]]; then
  shared="$(customer_shared '.grafana_image')"
  if [[ -n "${shared}" ]]; then
    V_GRAFANA_IMAGE="${shared}"
    log "grafana_image from ${CUSTOMER_BASE}"
  fi
fi
if [[ -z "${V_RBAC_EDIT}" ]]; then
  shared="$(customer_shared '.rbac.edit')"
  if [[ -n "${shared}" ]]; then
    V_RBAC_EDIT="${shared}"
    log "rbac.edit from ${CUSTOMER_BASE}"
  fi
fi
if [[ -z "${V_RBAC_VIEW}" ]]; then
  shared="$(customer_shared '.rbac.view')"
  if [[ -n "${shared}" ]]; then
    V_RBAC_VIEW="${shared}"
    log "rbac.view from ${CUSTOMER_BASE}"
  fi
fi

# ── Build RBAC lists ─────────────────────────────────────────────────
# Convert comma-separated strings to YAML list items
rbac_edit_yaml=""
if [[ -n "${V_RBAC_EDIT}" ]]; then
  IFS=',' read -ra groups <<< "${V_RBAC_EDIT}"
  for g in "${groups[@]}"; do
    g="${g#"${g%%[![:space:]]*}"}"   # trim leading space
    g="${g%"${g##*[![:space:]]}"}"   # trim trailing space
    rbac_edit_yaml="${rbac_edit_yaml}${rbac_edit_yaml:+, }${g}"
  done
fi
rbac_view_yaml=""
if [[ -n "${V_RBAC_VIEW}" ]]; then
  IFS=',' read -ra groups <<< "${V_RBAC_VIEW}"
  for g in "${groups[@]}"; do
    g="${g#"${g%%[![:space:]]*}"}"
    g="${g%"${g##*[![:space:]]}"}"
    rbac_view_yaml="${rbac_view_yaml}${rbac_view_yaml:+, }${g}"
  done
fi

# ── Read customer base labels/annotations ─────────────────────────────
CUST_LABELS=""
CUST_ANNOTATIONS=""
if [[ -f "${CUSTOMER_BASE}" ]]; then
  log "Merging customer base labels/annotations from ${CUSTOMER_BASE}"
  # Extract label lines (skip comments and standard keys)
  CUST_LABELS="$(yq '.project.labels // {} | to_entries | .[] | "    " + .key + ": \"" + .value + "\""' "${CUSTOMER_BASE}" 2>/dev/null || true)"
  CUST_ANNOTATIONS="$(yq '.project.annotations // {} | to_entries | .[] | "    " + .key + ": \"" + .value + "\""' "${CUSTOMER_BASE}" 2>/dev/null || true)"
fi

# ── Create overlay directory ─────────────────────────────────────────
mkdir -p "${OVERLAY_DIR}"
log "Generating overlay in ${OVERLAY_DIR}"

# ── Generate clusters.yaml ───────────────────────────────────────────
cat > "${OVERLAY_DIR}/clusters.yaml" <<EOF
#! Cluster identity for ${CLUSTER}.
---
clusters:
  - name: ${CLUSTER}
EOF
log "  Written: clusters.yaml"

# ── Generate values.yaml ────────────────────────────────────────────
cat > "${OVERLAY_DIR}/values.yaml" <<VALEOF
#@data/values
---
#! Cluster-specific overlay for ${CLUSTER^^}.
#! Generated by scripts/generate-overlay.sh from Vault path:
#!   ${VAULT_PATH}
#! Re-run the script to regenerate after Vault changes.

#! ── Vault-sourced secrets ────────────────────────────────────────────
#! Injected at render time from Vault (never committed to git).
#! Vault path: ${VAULT_PATH}
secrets:
  loki_storage:
    account_name: ""
    account_key: ""
    container: "${V_CONTAINER}"
    environment: "${V_ENVIRONMENT}"
    client_id: ""
    client_secret: ""
    tenant_id: ""
    grafana_admin_password: ""
    grafana_image: ""             #! Vault or _customer/values-base.yaml → gitops-secrets
    lokistack_size: "${V_LOKISTACK_SIZE}"
    management_state: "${V_MANAGEMENT_STATE}"
    storage_class: "${V_STORAGE_CLASS}"
    requests_cpu: ""
    requests_memory: ""
    limits_memory: ""
    rbac_edit: ""
    rbac_view: ""
    deployment_id: ""

node_placement:
  node_selector: {}
  tolerations: []

project:
  name: openshift-logging
  labels:
    kubernetes.io/metadata.name: openshift-logging
    argocd.argoproj.io/managed-by: "openshift-gitops"
    dt-monitoring: "true"
    openshift.io/cluster-monitoring: "true"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
${CUST_LABELS}
  annotations:
    openshift.io/node-selector: ""
    openshift.io/description: "OpenShift Logging LokiStack (audit + infrastructure)"
    openshift.io/display-name: openshift-logging
    argocd.argoproj.io/sync-wave: "1"
${CUST_ANNOTATIONS}
envs:
  - name: ${CLUSTER}
    rbac:
      edit: ${rbac_edit_yaml:-FILL_IN_AD_GROUP_EDIT}
      view: ${rbac_view_yaml:-FILL_IN_AD_GROUP_VIEW}
    deployment_id: ${V_DEPLOYMENT_ID}
    spec_hard:
      requests:
        cpu: ${V_REQUESTS_CPU}
        memory: ${V_REQUESTS_MEMORY}
      limits:
        memory: ${V_LIMITS_MEMORY}
      count:
        persistentvolumeclaims: 20
VALEOF
log "  Written: values.yaml"

# ── Generate gitops-secrets loki_storage block ───────────────────────
SECRETS_FILE="${OVERLAY_DIR}/gitops-secrets-loki-storage.yaml"
cat > "${SECRETS_FILE}" <<SECEOF
#! loki_storage block for the gitops-secrets Secret (openshift-gitops namespace).
#! Inject this into the secrets.yaml key of the gitops-secrets Secret.
#!
#! This file is NOT committed to git — it contains credentials.
#!
#! Generated from Vault path: ${VAULT_PATH}
#!
#! To apply: edit the gitops-secrets Secret in openshift-gitops and merge
#! the loki_storage block below into the existing secrets.yaml content,
#! under the secrets: key alongside azure:, redhat:, etc.
#!
#! Example secrets.yaml structure inside the Secret:
#!   #@data/values
#!   ---
#!   #@overlay/match missing_ok=True
#!   secrets:
#!     azure:
#!       ...existing platform secrets...
#!     loki_storage:
#!       ...paste the block below...

  loki_storage:
    account_name: "${V_ACCOUNT_NAME}"
    account_key: "${V_ACCOUNT_KEY}"
    container: "${V_CONTAINER}"
    environment: "${V_ENVIRONMENT}"
    client_id: "${V_CLIENT_ID}"
    client_secret: "${V_CLIENT_SECRET}"
    tenant_id: "${V_TENANT_ID}"
    grafana_admin_password: "${V_GRAFANA_PASSWORD}"
    grafana_image: "${V_GRAFANA_IMAGE}"
    lokistack_size: "${V_LOKISTACK_SIZE}"
    management_state: "${V_MANAGEMENT_STATE}"
    storage_class: "${V_STORAGE_CLASS}"
    requests_cpu: "${V_REQUESTS_CPU}"
    requests_memory: "${V_REQUESTS_MEMORY}"
    limits_memory: "${V_LIMITS_MEMORY}"
    rbac_edit: "${V_RBAC_EDIT}"
    rbac_view: "${V_RBAC_VIEW}"
    deployment_id: "${V_DEPLOYMENT_ID}"
SECEOF
log "  Written: gitops-secrets-loki-storage.yaml (DO NOT COMMIT)"

# ── Conjur secrets.tpl block ─────────────────────────────────────────
log ""
log "=========================================="
log "  Overlay generated for ${CLUSTER}"
log "=========================================="
log ""
log "Files created:"
log "  ${OVERLAY_DIR}/values.yaml           ← commit to git"
log "  ${OVERLAY_DIR}/clusters.yaml         ← commit to git"
log "  ${SECRETS_FILE}  ← DO NOT commit (contains credentials)"
log ""
log "Next steps:"
log "  1. Review and adjust values.yaml (node_placement, customer labels)"
log "  2. Commit values.yaml + clusters.yaml to the internal repo"
log "  3. Merge the loki_storage block from gitops-secrets-loki-storage.yaml"
log "     into the gitops-secrets Secret in openshift-gitops namespace:"
log ""
log "     oc get secret gitops-secrets -n openshift-gitops -o yaml > /tmp/gs.yaml"
log "     # Edit /tmp/gs.yaml: add loki_storage block to secrets.yaml data key"
log "     oc apply -f /tmp/gs.yaml"
log "     rm -f /tmp/gs.yaml"
log ""
log "  4. If Conjur CMP is used, also update secrets.tpl in the"
log "     openshift-gitops-secrets ConfigMap with the new keys."
log "     See _dev_docs/ SP auth checklist for the Conjur template."
log ""
log "  5. Trigger ArgoCD hard-refresh + sync"
