# Azure Storage Account Network ACL

Loki pods in `openshift-logging` must be able to reach the Azure Blob
Storage endpoint over HTTPS. On ARO clusters with VNet-integrated storage
accounts, the worker subnet must be explicitly allowed in the storage
account's network rules.

## Symptoms

If the worker subnet is missing from the ACL, Loki components (especially
the compactor) will fail with `AuthorizationFailure` (403) errors when
trying to reach Azure Blob Storage, even when the secret credentials are
correct.

## Automated fix

```bash
# az must already be logged in (`az login`).
# Cluster name finds the ARO resource group and worker subnet.
# Account name is not derived from the cluster name.
scripts/add-storage-subnet.sh --cluster arod05 --account-name <storage-account>
```

The script checks `az account show` before it calls Azure. It looks up the
ARO resource group and the storage account resource group. Those two are
often the same and do not need to be set. It is idempotent — safe to re-run.

If auto-discovery fails (e.g. insufficient Azure RBAC), pass the subnet
resource ID directly:

```bash
scripts/add-storage-subnet.sh \
  --account-name <storage-account> \
  --resource-group <storage-rg> \
  --subnet-id /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>
```

## Manual fix (Azure Portal)

1. Navigate to the storage account in Azure Portal
2. Go to **Networking** > **Firewalls and virtual networks**
3. Under **Virtual networks**, click **Add existing virtual network**
4. Select the ARO cluster's VNet and worker subnet
5. Click **Save**

## Manual fix (az CLI)

```bash
# 1. Find the worker subnet ID
SUBNET_ID=$(az aro show \
  --name <ARO_CLUSTER_NAME> \
  --resource-group <ARO_RESOURCE_GROUP> \
  --query 'workerProfiles[0].subnetId' -o tsv)

# 2. Add it to the storage account
az storage account network-rule add \
  --account-name <STORAGE_ACCOUNT_NAME> \
  --resource-group <STORAGE_RESOURCE_GROUP> \
  --subnet "${SUBNET_ID}"

# 3. Verify
az storage account network-rule list \
  --account-name <STORAGE_ACCOUNT_NAME> \
  --resource-group <STORAGE_RESOURCE_GROUP> \
  --query 'virtualNetworkRules[].virtualNetworkResourceId' -o tsv
```

## Verification

After adding the subnet, restart Loki pods if they were in a failure state:

```bash
oc rollout restart statefulset -n openshift-logging \
  -l app.kubernetes.io/instance=logging-loki
```

Check that the compactor and other components can connect:

```bash
oc logs -n openshift-logging -l app.kubernetes.io/component=compactor \
  --tail=20
```

## Note on propagation

Azure network rule changes may take a few minutes to propagate. If pods
still fail immediately after adding the rule, wait 5 minutes and try again.
