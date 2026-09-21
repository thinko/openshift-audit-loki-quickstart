#!/usr/bin/env bash
# Create a dedicated Azure Blob storage account for LokiStack, then one container.
# Does not create the OpenShift secret; `make deploy` does that from env vars.
#
# One storage account per environment type (sandbox/dev/test/prod).
# Additional clusters need only a container: scripts/create-azure-container.sh
# or this script with --container-only. Never share a container across LokiStacks.
# Do not reuse the ARO cluster or image-registry storage accounts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/create-azure-storage.sh [options]

Creates a StorageV2 account (Standard_LRS, TLS 1.2, no public blob access,
hierarchical namespace off) and one Blob container.

For another cluster on an account that already exists, do not run this.
Use scripts/create-azure-container.sh (or pass --container-only).

Required:
  AZURE_RESOURCE_GROUP          Resource group in the same region as the cluster
  or --resource-group NAME

Optional:
  AZURE_SUBSCRIPTION_ID         Subscription GUID (otherwise uses current az account)
  AZURE_CONTAINER_NAME          Blob container (default: {cluster}-audit-loki
                                from ARO_CLUSTER_NAME or CLUSTER)
  AZURE_STORAGE_ACCOUNT_NAME    Exact account name (3-24 lowercase alphanumeric)
  AZURE_STORAGE_ACCOUNT_PREFIX  Used when generating a name (default: lokiblob)
  AZURE_ENVIRONMENT             Written to the env file (default: AzureGlobal)
  AZURE_STORAGE_SKU             Default: Standard_LRS
  ENV_FILE                      Where exports are written (default: .env.azure)

Options:
  -g, --resource-group NAME
  -s, --subscription GUID
  -c, --container NAME
  -n, --name ACCOUNT            Explicit storage account name
  -p, --prefix PREFIX           Prefix for a generated account name
      --sku SKU
      --env-file PATH
      --cluster NAME            Cluster key for the default container name
      --container-only          Create a container on an existing account
      --login                   With --container-only, use Entra login
      --dry-run                 Print planned names; do not call Azure
  -h, --help

After a successful run:

  set -a && source .env.azure && set +a
  make deploy

The env file is gitignored. The account key is never printed to the terminal.
EOF
}

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
CONTAINER_NAME="${AZURE_CONTAINER_NAME:-}"
CLUSTER_NAME="${ARO_CLUSTER_NAME:-${CLUSTER:-}}"
ACCOUNT_NAME="${AZURE_STORAGE_ACCOUNT_NAME:-}"
ACCOUNT_PREFIX="${AZURE_STORAGE_ACCOUNT_PREFIX:-lokiblob}"
SKU="${AZURE_STORAGE_SKU:-Standard_LRS}"
AZURE_CLOUD_ENV="${AZURE_ENVIRONMENT:-AzureGlobal}"
ENV_FILE="${ENV_FILE:-${ROOT}/.env.azure}"
DRY_RUN=0
CONTAINER_ONLY=0
USE_LOGIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="${2:?}"; shift 2 ;;
    -s|--subscription) SUBSCRIPTION_ID="${2:?}"; shift 2 ;;
    -c|--container) CONTAINER_NAME="${2:?}"; shift 2 ;;
    --cluster) CLUSTER_NAME="${2:?}"; shift 2 ;;
    -n|--name) ACCOUNT_NAME="${2:?}"; shift 2 ;;
    -p|--prefix) ACCOUNT_PREFIX="${2:?}"; shift 2 ;;
    --sku) SKU="${2:?}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?}"; shift 2 ;;
    --container-only) CONTAINER_ONLY=1; shift ;;
    --login) USE_LOGIN=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_az_login

[[ -n "${RESOURCE_GROUP}" ]] || die "Set AZURE_RESOURCE_GROUP or pass --resource-group"

if [[ -z "${CONTAINER_NAME}" ]]; then
  export ARO_CLUSTER_NAME="${CLUSTER_NAME}"
  CONTAINER_NAME="$(azure_blob_container_name)" || die "Pass --container, or --cluster / ARO_CLUSTER_NAME. Default is {cluster}-audit-loki."
fi

if [[ "${CONTAINER_ONLY}" -eq 1 ]]; then
  [[ -n "${ACCOUNT_NAME}" ]] || die "Container-only mode needs an existing account: --name or AZURE_STORAGE_ACCOUNT_NAME"
  args=(
    --resource-group "${RESOURCE_GROUP}"
    --name "${ACCOUNT_NAME}"
    --container "${CONTAINER_NAME}"
  )
  [[ -n "${SUBSCRIPTION_ID}" ]] && args+=(--subscription "${SUBSCRIPTION_ID}")
  [[ "${USE_LOGIN}" -eq 1 ]] && args+=(--login)
  [[ "${DRY_RUN}" -eq 1 ]] && args+=(--dry-run)
  exec "${SCRIPT_DIR}/create-azure-container.sh" "${args[@]}"
fi

if [[ ! "${CONTAINER_NAME}" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])$ ]]; then
  die "Container name '${CONTAINER_NAME}' must be 3-63 characters, lowercase letters, numbers, and hyphens."
fi

if [[ -z "${ACCOUNT_NAME}" ]]; then
  need_cmd openssl
  ACCOUNT_NAME="${ACCOUNT_PREFIX}$(openssl rand -hex 3)"
fi
ACCOUNT_NAME="$(printf '%s' "${ACCOUNT_NAME}" | tr '[:upper:]' '[:lower:]')"

if [[ ! "${ACCOUNT_NAME}" =~ ^[a-z0-9]{3,24}$ ]]; then
  die "Storage account name '${ACCOUNT_NAME}' must be 3-24 lowercase letters and numbers (no hyphens)."
fi

case "${AZURE_CLOUD_ENV}" in
  AzureGlobal|AzureChinaCloud|AzureGermanCloud|AzureUSGovernment) ;;
  *) die "AZURE_ENVIRONMENT must be AzureGlobal, AzureChinaCloud, AzureGermanCloud, or AzureUSGovernment" ;;
esac

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  log "Setting Azure subscription ${SUBSCRIPTION_ID}"
  [[ "${DRY_RUN}" -eq 1 ]] || az account set --subscription "${SUBSCRIPTION_ID}"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "Dry run: would create account ${ACCOUNT_NAME} in ${RESOURCE_GROUP}, container ${CONTAINER_NAME}"
  exit 0
fi

log "Resolving location from resource group ${RESOURCE_GROUP}"
LOCATION="$(az group show --name "${RESOURCE_GROUP}" --query location -o tsv)"
[[ -n "${LOCATION}" ]] || die "Could not read location for resource group ${RESOURCE_GROUP}"
log "Location: ${LOCATION}"
log "Storage account: ${ACCOUNT_NAME}"
log "Container: ${CONTAINER_NAME}"

log "Creating storage account (key is not printed)"
az storage account create \
  --name "${ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --sku "${SKU}" \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --https-only true \
  --enable-hierarchical-namespace false \
  --tags purpose=loki-audit workload=openshift-logging

STORAGE_KEY=""
if STORAGE_KEY="$(az storage account keys list \
  --resource-group "${RESOURCE_GROUP}" \
  --account-name "${ACCOUNT_NAME}" \
  --query "[0].value" -o tsv)"; then
  :
else
  log "Could not read an account key (shared key access may be disabled)."
  STORAGE_KEY=""
fi

container_args=(
  --resource-group "${RESOURCE_GROUP}"
  --name "${ACCOUNT_NAME}"
  --container "${CONTAINER_NAME}"
  --quiet
)
if [[ -n "${STORAGE_KEY}" ]]; then
  AZURE_STORAGE_KEY="${STORAGE_KEY}" "${SCRIPT_DIR}/create-azure-container.sh" "${container_args[@]}"
else
  log "Creating the container with Entra login."
  "${SCRIPT_DIR}/create-azure-container.sh" --login "${container_args[@]}"
fi

umask 077
{
  echo "# Generated by scripts/create-azure-storage.sh — do not commit."
  echo "export AZURE_STORAGE_ACCOUNT_NAME='${ACCOUNT_NAME}'"
  if [[ -n "${STORAGE_KEY}" ]]; then
    echo "export AZURE_STORAGE_ACCOUNT_KEY='${STORAGE_KEY}'"
  else
    echo "# No account key: shared key access is disabled. Use SP or token auth."
  fi
  echo "export AZURE_CONTAINER_NAME='${CONTAINER_NAME}'"
  echo "export AZURE_ENVIRONMENT='${AZURE_CLOUD_ENV}'"
} > "${ENV_FILE}"
unset STORAGE_KEY

log "Wrote ${ENV_FILE} (gitignored). Account key is not printed."
cat <<EOF

Next (same shell):

  set -a && source ${ENV_FILE} && set +a
  make deploy

LokiStack expects OpenShift secret logging-loki-azure; deploy.sh creates it.
EOF
