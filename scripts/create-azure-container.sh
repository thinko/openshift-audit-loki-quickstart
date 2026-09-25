#!/usr/bin/env bash
# Create a Blob container on an existing Loki storage account.
# Does not create a storage account or the OpenShift secret.
#
# One storage account per environment type (sandbox/dev/test/prod).
# One container per cluster. Never share a container across LokiStacks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/create-azure-container.sh [options]

Creates one Blob container on an existing storage account. Use this for each
new cluster. Create the account once per environment with
scripts/create-azure-storage.sh.

Required:
  AZURE_STORAGE_ACCOUNT_NAME  or  --name ACCOUNT
  ARO_CLUSTER_NAME / CLUSTER  or  --cluster NAME
                                  Container name becomes {cluster}-audit-loki
                                  (arod05 -> arod05-audit-loki).
                                  Or pass --container to override that name.

Optional:
  AZURE_RESOURCE_GROUP        or  --resource-group NAME
                                  Discovered from the storage account name.
  AZURE_SUBSCRIPTION_ID       or  --subscription GUID
  AZURE_STORAGE_ACCOUNT_KEY   Account key. When unset, uses Entra login
                              (--auth-mode login). Prefer login when shared
                              key access is disabled.

Options:
  -n, --name ACCOUNT
  -g, --resource-group NAME
  -c, --container NAME
      --cluster NAME          Cluster key; sets the container name when
                              --container is omitted
  -s, --subscription GUID
      --login                 Use Entra login even if an account key is set
      --quiet                 Do not print follow-up commands
      --dry-run               Print the planned container; do not call Azure
  -h, --help

The account key is read from the environment and is never printed.
EOF
}

ACCOUNT_NAME="${AZURE_STORAGE_ACCOUNT_NAME:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
CONTAINER_NAME="${AZURE_CONTAINER_NAME:-}"
CLUSTER_NAME="${ARO_CLUSTER_NAME:-${CLUSTER:-}}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
USE_LOGIN=0
QUIET=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)            ACCOUNT_NAME="${2:?}"; shift 2 ;;
    -g|--resource-group)  RESOURCE_GROUP="${2:?}"; shift 2 ;;
    -c|--container)       CONTAINER_NAME="${2:?}"; shift 2 ;;
    --cluster)            CLUSTER_NAME="${2:?}"; shift 2 ;;
    -s|--subscription)    SUBSCRIPTION_ID="${2:?}"; shift 2 ;;
    --login)              USE_LOGIN=1; shift ;;
    --quiet)              QUIET=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "Unknown argument: $1" ;;
  esac
done

require_az_login

[[ -n "${ACCOUNT_NAME}" ]] || die "Set AZURE_STORAGE_ACCOUNT_NAME or pass --name"

if [[ -z "${CONTAINER_NAME}" ]]; then
  export ARO_CLUSTER_NAME="${CLUSTER_NAME}"
  CONTAINER_NAME="$(azure_blob_container_name)" || die "Pass --cluster (for example arod05), or pass --container. Default is {cluster}-audit-loki (one container per cluster)."
fi

ACCOUNT_NAME="$(printf '%s' "${ACCOUNT_NAME}" | tr '[:upper:]' '[:lower:]')"
CONTAINER_NAME="$(printf '%s' "${CONTAINER_NAME}" | tr '[:upper:]' '[:lower:]')"

if [[ ! "${ACCOUNT_NAME}" =~ ^[a-z0-9]{3,24}$ ]]; then
  die "Storage account name '${ACCOUNT_NAME}' must be 3-24 lowercase letters and numbers (no hyphens)."
fi
if [[ ! "${CONTAINER_NAME}" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])$ ]]; then
  die "Container name '${CONTAINER_NAME}' must be 3-63 characters, lowercase letters, numbers, and hyphens."
fi

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  log "Setting Azure subscription ${SUBSCRIPTION_ID}"
  az account set --subscription "${SUBSCRIPTION_ID}"
fi

if [[ -z "${RESOURCE_GROUP}" ]]; then
  local_rg="$(az storage account list --query "[?name=='${ACCOUNT_NAME}'].resourceGroup" -o tsv)"
  local_count="$(printf '%s\n' "${local_rg}" | grep -c . || true)"
  if [[ "${local_count}" -ne 1 ]]; then
    die "Could not find storage account ${ACCOUNT_NAME} in this subscription. Pass --resource-group."
  fi
  RESOURCE_GROUP="${local_rg}"
  log "Storage account resource group: ${RESOURCE_GROUP}"
fi

# Determine auth mode.  The dummy placeholder key that load-cluster-env
# provides (double-base64 of "unused") is not a real key — treat it
# the same as "no key set" and fall through to Entra login.
_dummy_key="$(printf 'unused' | base64 | tr -d '\n' | base64 | tr -d '\n')"
_effective_key="${AZURE_STORAGE_ACCOUNT_KEY:-}${AZURE_STORAGE_KEY:-}"
if [[ "${_effective_key}" == "${_dummy_key}" || "${_effective_key}" == "unused" ]]; then
  _effective_key=""
fi

if [[ "${USE_LOGIN}" -eq 1 || -z "${_effective_key}" ]]; then
  AUTH_MODE="login"
else
  AUTH_MODE="key"
  export AZURE_STORAGE_KEY="${AZURE_STORAGE_KEY:-${AZURE_STORAGE_ACCOUNT_KEY}}"
fi
unset _dummy_key _effective_key

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "Dry run: would create container ${CONTAINER_NAME} on ${ACCOUNT_NAME} (${RESOURCE_GROUP}) using ${AUTH_MODE} auth"
  exit 0
fi

log "Checking storage account ${ACCOUNT_NAME} in ${RESOURCE_GROUP}"
az storage account show \
  --name "${ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query name -o tsv >/dev/null

log "Creating blob container ${CONTAINER_NAME} on ${ACCOUNT_NAME} (${AUTH_MODE} auth)"
if [[ "${AUTH_MODE}" == "login" ]]; then
  az storage container create \
    --name "${CONTAINER_NAME}" \
    --account-name "${ACCOUNT_NAME}" \
    --auth-mode login \
    --public-access off >/dev/null
else
  az storage container create \
    --name "${CONTAINER_NAME}" \
    --account-name "${ACCOUNT_NAME}" \
    --public-access off >/dev/null
fi

log "Container ${CONTAINER_NAME} is ready on ${ACCOUNT_NAME}"
[[ "${QUIET}" -eq 1 ]] && exit 0
cat <<EOF

Next, point this cluster at that container (do not reuse it on another cluster):

  export AZURE_STORAGE_ACCOUNT_NAME='${ACCOUNT_NAME}'
  export AZURE_CONTAINER_NAME='${CONTAINER_NAME}'

Then add this cluster's worker subnet if it is not already on the account:

  make add-storage-subnet
EOF
