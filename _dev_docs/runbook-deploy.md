# Deployment Runbook: LokiStack on Sandbox

Step-by-step guide for completing the LokiStack deployment once the Azure Blob
storage account is delivered by Cloud Ops.

## Prerequisites (already done)

- [x] Operators installed: `loki-operator.v6.5.2` + `cluster-logging.v6.5.2` (Succeeded)
- [x] OperatorGroup conflict resolved (single OG per namespace)
- [x] CRDs present: `lokistacks.loki.grafana.com`, `clusterlogforwarders.observability.openshift.io`
- [x] StorageClass `managed-csi` available
- [x] Pre-existing CLF `instance` (Azure Monitor) identified — keeping it

## Prerequisites (pending)

- [ ] Collector RBAC pre-applied (`make apply-rbac`)
- [ ] Azure Blob storage account + container delivered by Cloud Ops
- [ ] Network egress to `*.blob.core.windows.net` confirmed (`make check-egress`)

## Step 1: Receive the storage account credentials

Cloud Ops will provide (from the ServiceNow ticket):
- **Storage account name** (e.g. `lokiblobsbx01`)
- **Storage account key** (Base64, ~88 chars)
- **Container name** (request `loki-audit` or create it yourself)

If they created the secret directly in the cluster, skip to Step 3.

## Step 2: Run the full deployment

```bash
cd /path/to/openshift-audit-loki-quickstart

# Set credentials
export AZURE_STORAGE_ACCOUNT_NAME='<account-name>'
export AZURE_STORAGE_ACCOUNT_KEY='<account-key>'
export AZURE_CONTAINER_NAME='loki-audit'

# Optional: run preflight first
make preflight

# Deploy everything
make deploy
```

`make deploy` will:
1. Verify namespaces and OperatorGroups (pre-flight)
2. Apply operator subscriptions (already installed, no-op)
3. Create the `logging-loki-azure` secret from the env vars
4. Apply the `LokiStack` CR and wait for `Ready=True`
5. Apply collector RBAC + `ClusterLogForwarder` `loki-audit`
6. Enable the `logging-view-plugin` console plugin

## Step 3: Verify the deployment

```bash
make status
```

Expected output:
- Both CSVs: Succeeded
- Azure Blob secret: complete (values not printed)
- LokiStack: Ready=True
- ClusterLogForwarder `loki-audit`: conditions ready
- Collector pods: Running (one per node)

Also check:
```bash
oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.status.conditions[*].type}{"\n"}'
oc get pods -n openshift-logging -l app.kubernetes.io/name=lokistack
```

## Step 4: Test user attribution

```bash
make test-attribution
```

This creates and deletes a test ConfigMap, then prints the LogQL query and
console steps to verify the audit event landed with correct user attribution.

Wait 30-90 seconds after running, then check:
1. **Console**: Observe -> Logs -> Audit tenant -> paste the query
2. Verify `user.username` matches `oc whoami`

## Step 5: Console verification

1. Open the OpenShift web console
2. Navigate to **Observe -> Logs**
3. Select the **Audit** tenant (not Application or Infrastructure)
4. Time range: Last 15 minutes
5. Run: `{log_type="audit"} | json | verb="delete"`

## Troubleshooting

### LokiStack stuck in Pending

```bash
oc describe lokistack logging-loki -n openshift-logging
oc get pods -n openshift-logging -l app.kubernetes.io/name=lokistack
oc logs -n openshift-logging -l app.kubernetes.io/component=compactor --tail=30
```

Common causes:
- Azure secret keys incorrect (check `account_name`, `account_key`, `container`, `environment`)
- Container does not exist in the storage account
- Network egress blocked to `*.blob.core.windows.net`
- PVCs stuck (check `oc get pvc -n openshift-logging`)

### Collector pods not starting

```bash
oc get clusterlogforwarder loki-audit -n openshift-logging -o yaml
oc get daemonset -n openshift-logging -l app.kubernetes.io/name=clusterlogforwarder
oc logs -n openshift-logging -l app.kubernetes.io/component=collector --tail=30
```

Common causes:
- ClusterRoleBindings missing (`make apply-rbac`)
- LokiStack not Ready yet (collector waits for the gateway)
- ServiceAccount `logging-collector` not found

### Rollback

```bash
make destroy          # prompts for confirmation
# or
make destroy ARGS="--yes"
```

This removes the CLF, LokiStack, RBAC, and Azure secret. The Blob container
data is NOT deleted. Operators stay unless `--purge-operators` is passed.

## Contact

- LogQL query reference: `docs/logql-queries.md`
- Azure Blob request template: `docs/azure-blob-request.md`
- Session notes: `_dev_docs/2026-08-26-sandbox-operator-fix.md`
