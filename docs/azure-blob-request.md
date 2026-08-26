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

## Network connectivity (critical)

Loki pods in `openshift-logging` must be able to **resolve and reach**
`<account>.blob.core.windows.net` over HTTPS (port 443).

### Private ARO clusters

On ARO clusters with private networking and custom DNS servers, the cluster
**cannot resolve public Azure endpoints** by default. The storage account
needs all three of:

1. **Private Endpoint** — create a Private Endpoint for the Blob service in the
   ARO cluster's VNet (or a VNet peered to it).
2. **Private DNS Zone** — create (or reuse) a Private DNS Zone for
   `privatelink.blob.core.windows.net` and link it to the VNet. Azure
   automatically registers an A record mapping
   `<account>.blob.core.windows.net` → private endpoint IP.
3. **DNS forwarding** — the VNet's custom DNS servers must conditionally
   forward `blob.core.windows.net` queries to Azure DNS (`168.63.129.16`)
   or to the Private DNS Zone.

Without these, Loki will fail with connection-refused or DNS-resolution errors.

### Verification

After the storage account and private endpoint are provisioned, run from the
repo root:

```bash
make check-egress                   # generic blob.core.windows.net test
AZURE_BLOB_HOST=<account>.blob.core.windows.net make check-egress  # account-specific
```

Both should show `PASS` for DNS resolution and HTTPS connectivity.

### Note

Disk StorageClasses (`managed-csi`) are unrelated — they use the Azure disk
API, not Blob. A working `managed-csi` does **not** mean Blob is reachable.
