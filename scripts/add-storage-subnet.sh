#!/usr/bin/env bash
# Add an ARO cluster's worker subnet to the Azure storage account network
# ACL so Loki pods can reach Azure Blob Storage over the VNet.
#
# Idempotent: checks whether the rule already exists before adding.
#
# Required (env or flags):
#   AZURE_STORAGE_ACCOUNT_NAME / --account-name
#   AZURE_RESOURCE_GROUP       / --resource-group    (storage account RG)
#
# Subnet discovery (provide ONE of):
#   ARO_CLUSTER_NAME + ARO_RESOURCE_GROUP  — auto-discovers worker subnet
#   --subnet-id <full-resource-id>         — explicit subnet resource ID
#
# Optional:
#   AZURE_SUBSCRIPTION_ID / --subscription  — defaults to current az account
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
  AZURE_STORAGE_ACCOUNT_NAME  or  --account-name NAME
  AZURE_RESOURCE_GROUP        or  --resource-group NAME

Subnet (one of):
  ARO_CLUSTER_NAME + ARO_RESOURCE_GROUP   Auto-discover via `az aro show`
  --subnet-id RESOURCE_ID                 Full Azure resource ID of the subnet

Optional:
  AZURE_SUBSCRIPTION_ID  or  --subscription GUID
  --dry-run              Print what would be done without making changes

Options:
  -h, --help

Manual equivalent (Azure Portal):
  Storage account > Networking > Firewalls and virtual networks
  > Virtual networks > Add existing virtual network
  Select the ARO worker subnet, then Save.

Manual equivalent (az CLI):
  az storage account network-rule add \
    --account-name <name> --resource-group <rg> \
    --subnet <full-subnet-resource-id>
EOF
}

ACCOUNT_NAME="${AZURE_STORAGE_ACCOUNT_NAME:-}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
ARO_CLUSTER="${ARO_CLUSTER_NAME:-}"
ARO_RG="${ARO_RESOURCE_GROUP:-}"
SUBNET_ID=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account-name)   ACCOUNT_NAME="${2:?}"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="${2:?}"; shift 2 ;;
    --subscription)   SUBSCRIPTION_ID="${2:?}"; shift 2 ;;
    --subnet-id)      SUBNET_ID="${2:?}"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "Unknown argument: $1" ;;
  esac
done

need_cmd az

[[ -n "${ACCOUNT_NAME}" ]]  || die "Set AZURE_STORAGE_ACCOUNT_NAME or pass --account-name"
[[ -n "${RESOURCE_GROUP}" ]] || die "Set AZURE_RESOURCE_GROUP or pass --resource-group"

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  log "Setting Azure subscription ${SUBSCRIPTION_ID}"
  [[ "${DRY_RUN}" -eq 1 ]] || az account set --subscription "${SUBSCRIPTION_ID}"
fi

# ── Discover worker subnet ──
if [[ -z "${SUBNET_ID}" ]]; then
  [[ -n "${ARO_CLUSTER}" ]] || die "Provide --subnet-id or set ARO_CLUSTER_NAME for auto-discovery"
  [[ -n "${ARO_RG}" ]]      || die "Set ARO_RESOURCE_GROUP when using ARO_CLUSTER_NAME"

  log "Discovering worker subnet from ARO cluster ${ARO_CLUSTER} in ${ARO_RG}"
  SUBNET_ID="$(az aro show \
    --name "${ARO_CLUSTER}" \
    --resource-group "${ARO_RG}" \
    --query 'workerProfiles[0].subnetId' -o tsv 2>/dev/null || true)"

  if [[ -z "${SUBNET_ID}" ]]; then
    die "Could not discover worker subnet from ARO cluster ${ARO_CLUSTER}.
Check: az aro show --name ${ARO_CLUSTER} -g ${ARO_RG} --query 'workerProfiles[0].subnetId'"
  fi
  log "Discovered subnet: ${SUBNET_ID}"
fi

# ── Check if rule already exists ──
log "Checking existing network rules on storage account ${ACCOUNT_NAME}"
EXISTING_SUBNETS="$(az storage account network-rule list \
  --account-name "${ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query 'virtualNetworkRules[].virtualNetworkResourceId' -o tsv 2>/dev/null || true)"

if echo "${EXISTING_SUBNETS}" | grep -qF "${SUBNET_ID}"; then
  log "Subnet is already in the network rules. Nothing to do."
  exit 0
fi

# ── Add the rule ──
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

# ── Verify ──
log "Verifying rule was added"
VERIFY="$(az storage account network-rule list \
  --account-name "${ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query 'virtualNetworkRules[].virtualNetworkResourceId' -o tsv 2>/dev/null || true)"

if echo "${VERIFY}" | grep -qF "${SUBNET_ID}"; then
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
