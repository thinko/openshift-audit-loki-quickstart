#!/usr/bin/env bash
# Add an ARO cluster's worker subnet to the Azure storage account network
# ACL so Loki pods can reach Azure Blob Storage over the VNet.
#
# Idempotent: checks whether the rule already exists before adding.
#
# The cluster name is enough to find the ARO resource group and worker subnet.
# The storage account name is not encoded in the cluster name. Pass it, or
# rely on a single subscription account tagged purpose=loki-audit.
# Its resource group is looked up from the account. ARO_RESOURCE_GROUP and
# AZURE_RESOURCE_GROUP are optional overrides.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/add-storage-subnet.sh [options]

Adds the ARO worker subnet to the storage account's network rules so Loki
pods can reach Azure Blob Storage via the VNet service endpoint.

Required:
  --cluster / ARO_CLUSTER_NAME / CLUSTER
      ARO cluster name, for example arod05. The resource group and worker
      subnet are read from `az aro list` / `az aro show`.

  --account-name / AZURE_STORAGE_ACCOUNT_NAME
      Loki storage account. Not derived from the cluster name. Omitted only
      when this subscription has exactly one account tagged purpose=loki-audit.

Optional:
  --resource-group / AZURE_RESOURCE_GROUP
      Storage account resource group. Discovered from the account name.
  --aro-resource-group / ARO_RESOURCE_GROUP
      ARO resource group. Discovered from the cluster name. Often the same
      value as the storage account resource group, but not assumed.
  --subnet-id RESOURCE_ID
      Skip cluster lookup and use this subnet.
  --subscription / AZURE_SUBSCRIPTION_ID
  --dry-run

The script checks `az account show` first and stops if the CLI is not logged in.
EOF
}

ACCOUNT_NAME="${AZURE_STORAGE_ACCOUNT_NAME:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
ARO_CLUSTER="${ARO_CLUSTER_NAME:-${CLUSTER:-}}"
ARO_RG="${ARO_RESOURCE_GROUP:-}"
SUBNET_ID=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account-name)        ACCOUNT_NAME="${2:?}"; shift 2 ;;
    --resource-group)      RESOURCE_GROUP="${2:?}"; shift 2 ;;
    --aro-resource-group)  ARO_RG="${2:?}"; shift 2 ;;
    --cluster)             ARO_CLUSTER="${2:?}"; shift 2 ;;
    --subscription)        SUBSCRIPTION_ID="${2:?}"; shift 2 ;;
    --subnet-id)           SUBNET_ID="${2:?}"; shift 2 ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *)                     die "Unknown argument: $1" ;;
  esac
done

require_az_login

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  log "Setting Azure subscription ${SUBSCRIPTION_ID}"
  az account set --subscription "${SUBSCRIPTION_ID}"
fi

discover_aro_resource_group() {
  local want matches count
  want="$(printf '%s' "${ARO_CLUSTER}" | tr '[:upper:]' '[:lower:]')"
  log "Looking up ARO cluster ${want}"
  matches="$(az aro list --query '[].{name:name, rg:resourceGroup}' -o tsv \
    | awk -v n="${want}" 'tolower($1)==n { rg=$2; for (i=3; i<=NF; i++) rg=rg " " $i; print rg }')"
  count="$(printf '%s\n' "${matches}" | grep -c . || true)"
  if [[ "${count}" -eq 0 ]]; then
    die "No ARO cluster named ${want} in the current subscription.
az is logged in. Check the name and subscription:
  az aro list -o table
Or pass --aro-resource-group if the cluster is in a subscription you have not selected."
  fi
  if [[ "${count}" -gt 1 ]]; then
    die "More than one ARO cluster is named ${want}. Pass --aro-resource-group.
${matches}"
  fi
  ARO_RG="${matches}"
  log "ARO resource group: ${ARO_RG}"
}

discover_worker_subnet() {
  local err_file
  err_file="$(mktemp)"
  if [[ -z "${ARO_RG}" ]]; then
    discover_aro_resource_group
  else
    log "Using ARO resource group ${ARO_RG}"
  fi
  log "Reading worker subnet from ARO cluster ${ARO_CLUSTER}"
  if ! SUBNET_ID="$(az aro show \
    --name "${ARO_CLUSTER}" \
    --resource-group "${ARO_RG}" \
    --query 'workerProfiles[0].subnetId' -o tsv 2>"${err_file}")"; then
    die "az aro show failed for ${ARO_CLUSTER} in ${ARO_RG}:
$(cat "${err_file}")"
  fi
  rm -f "${err_file}"
  [[ -n "${SUBNET_ID}" ]] || die "ARO cluster ${ARO_CLUSTER} has no workerProfiles[0].subnetId."
  log "Discovered subnet: ${SUBNET_ID}"
}

discover_storage_account() {
  local tagged count preferred
  if [[ -n "${ACCOUNT_NAME}" ]]; then
    return 0
  fi
  log "No storage account name given. Searching for purpose=loki-audit."
  tagged="$(az resource list \
    --resource-type Microsoft.Storage/storageAccounts \
    --query "[?tags.purpose=='loki-audit'].[name,resourceGroup]" -o tsv)"
  count="$(printf '%s\n' "${tagged}" | grep -c . || true)"
  if [[ "${count}" -eq 0 ]]; then
    die "Could not choose a storage account from cluster ${ARO_CLUSTER:-<unset>}.
The account name is not derived from the cluster name. Pass --account-name.
Resource groups are discovered and do not need to be set."
  fi
  if [[ "${count}" -eq 1 ]]; then
    ACCOUNT_NAME="$(printf '%s\n' "${tagged}" | awk '{print $1}')"
    RESOURCE_GROUP="${RESOURCE_GROUP:-$(printf '%s\n' "${tagged}" | awk '{print $2}')}"
    log "Using tagged storage account ${ACCOUNT_NAME} in ${RESOURCE_GROUP}"
    return 0
  fi
  if [[ -n "${ARO_RG}" ]]; then
    preferred="$(printf '%s\n' "${tagged}" | awk -v rg="${ARO_RG}" '$2==rg {print}')"
    count="$(printf '%s\n' "${preferred}" | grep -c . || true)"
    if [[ "${count}" -eq 1 ]]; then
      ACCOUNT_NAME="$(printf '%s\n' "${preferred}" | awk '{print $1}')"
      RESOURCE_GROUP="${ARO_RG}"
      log "Using tagged storage account ${ACCOUNT_NAME} in the ARO resource group"
      return 0
    fi
  fi
  die "Several storage accounts are tagged purpose=loki-audit. Pass --account-name.
${tagged}"
}

discover_storage_resource_group() {
  local found count
  if [[ -n "${RESOURCE_GROUP}" ]]; then
    log "Using storage resource group ${RESOURCE_GROUP}"
    return 0
  fi
  log "Looking up resource group for storage account ${ACCOUNT_NAME}"
  found="$(az storage account list --query "[?name=='${ACCOUNT_NAME}'].resourceGroup" -o tsv)"
  count="$(printf '%s\n' "${found}" | grep -c . || true)"
  if [[ "${count}" -eq 1 ]]; then
    RESOURCE_GROUP="${found}"
    log "Storage account resource group: ${RESOURCE_GROUP}"
    return 0
  fi
  if [[ "${count}" -eq 0 && -n "${ARO_RG}" ]]; then
    log "Account was not listed in this subscription. Trying the ARO resource group ${ARO_RG}."
    if az storage account show --name "${ACCOUNT_NAME}" --resource-group "${ARO_RG}" --query name -o tsv >/dev/null; then
      RESOURCE_GROUP="${ARO_RG}"
      log "Storage account is in the ARO resource group"
      return 0
    fi
  fi
  die "Could not find storage account ${ACCOUNT_NAME} in this subscription. Pass --resource-group."
}

if [[ -z "${SUBNET_ID}" ]]; then
  [[ -n "${ARO_CLUSTER}" ]] || die "Pass --cluster (for example arod05), or pass --subnet-id."
  discover_worker_subnet
else
  log "Using subnet ${SUBNET_ID}"
fi

discover_storage_account
[[ -n "${ACCOUNT_NAME}" ]] || die "Pass --account-name. It cannot be derived from the cluster name."
discover_storage_resource_group

log "Checking existing network rules on storage account ${ACCOUNT_NAME}"
EXISTING_SUBNETS="$(az storage account network-rule list \
  --account-name "${ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query 'virtualNetworkRules[].virtualNetworkResourceId' -o tsv)"

if printf '%s\n' "${EXISTING_SUBNETS}" | grep -qF "${SUBNET_ID}"; then
  log "Subnet is already in the network rules. Nothing to do."
  exit 0
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "Dry run: would add subnet to storage account network rules:"
  log "  Account: ${ACCOUNT_NAME}"
  log "  RG:      ${RESOURCE_GROUP}"
  log "  Subnet:  ${SUBNET_ID}"
  exit 0
fi

log "Adding worker subnet to storage account network rules"
az storage account network-rule add \
  --account-name "${ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --subnet "${SUBNET_ID}"

log "Verifying rule was added"
VERIFY="$(az storage account network-rule list \
  --account-name "${ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query 'virtualNetworkRules[].virtualNetworkResourceId' -o tsv)"

if printf '%s\n' "${VERIFY}" | grep -qF "${SUBNET_ID}"; then
  log "Subnet successfully added to storage account network rules"
else
  err "Rule add command succeeded but subnet not found in verification. Check Azure Portal."
  exit 1
fi

echo ""
echo "Storage account ${ACCOUNT_NAME} now allows traffic from:"
echo "  ${SUBNET_ID}"
echo ""
echo "Note: it may take a few minutes for the rule to propagate."
echo "Loki pods may need a restart if they were failing Azure auth:"
echo "  oc rollout restart statefulset -n openshift-logging -l app.kubernetes.io/instance=logging-loki"
