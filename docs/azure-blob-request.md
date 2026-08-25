# Azure Blob request for LokiStack

Use this when a cloud team must provision object storage instead of
`scripts/create-azure-storage.sh`. Paste the fields below into the change
ticket. Do **not** reuse the ARO cluster or image-registry storage accounts.

## Ask for

| Field | Value |
| --- | --- |
| Kind | StorageV2 |
| SKU | `Standard_LRS` (sandbox/dev). Use ZRS only if policy requires it. |
| Region | Same region as the ARO resource group |
| TLS | Minimum TLS 1.2 |
| Public blob access | Disabled |
| HTTPS only | Enabled |
| Hierarchical namespace (ADLS Gen2) | **Disabled** — Loki uses classic Blob |
| Container | Unique per cluster, e.g. `loki-audit` (3–63 chars, lowercase, hyphens ok) |
| Account name | Globally unique, 3–24 lowercase alphanumeric. One account per environment type is enough if each cluster gets its own container. |

Optional tags: `purpose=loki-audit`, `workload=openshift-logging`.

## Deliver back to the OpenShift installers

One of:

1. **Account name, account key, container name** (and cloud environment: `AzureGlobal` unless China/US Gov/Germany). Installers run:

   ```bash
   export AZURE_STORAGE_ACCOUNT_NAME='...'
   export AZURE_STORAGE_ACCOUNT_KEY='...'
   export AZURE_CONTAINER_NAME='...'
   export AZURE_ENVIRONMENT='AzureGlobal'
   make deploy
   ```

2. **Or** an Opaque Secret in `openshift-logging` named `logging-loki-azure`:

   | Secret key | Maps to |
   | --- | --- |
   | `account_name` | Storage account name |
   | `account_key` | Key1 (or Key2) |
   | `container` | Blob container |
   | `environment` | `AzureGlobal` |

   Then installers run `make deploy` with no Azure env vars.

Do not copy `azure-cloud-credentials` from `openshift-azure-operator` or
`kube-system`. Those are the cluster service principal, not Blob keys.

## Network

Loki pods in `openshift-logging` must reach `*.blob.core.windows.net` (or the
sovereign cloud equivalent). If the account is firewalled, allow the cluster
egress IPs or a private endpoint. Disk StorageClasses (`managed-csi`) are
unrelated and already sufficient for Loki PVCs.
