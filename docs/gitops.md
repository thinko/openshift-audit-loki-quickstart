# GitOps handoff

This kit supports two install paths:

| Path | When |
|------|------|
| `make deploy` / Helm | Laptop or sandbox. See the README quickstart. |
| `gitops/namespaces/openshift-logging/` | Argo CD via an internal git repo that is **already** registered in Argo over SSH. |

Argo must clone a git URL the cluster can reach. A laptop working copy is not a source. Do not register this public GitHub repository as the Argo source for a customer cluster.

## What to copy

Copy the folder

```text
gitops/namespaces/openshift-logging/
```

into `namespaces/openshift-logging/` on the Argo-watched git repo (folder name matches the destination namespace). Open a PR there.

The folder follows the same mix used for other multi-manifest namespaces:

- `clusters.yaml` and ytt `#@data/values` `values.yaml` — ApplicationSet inputs
- Sibling **plain** YAML — OperatorGroup, Subscriptions, LokiStack, collector RBAC, ClusterLogForwarder, Grafana, UIPlugin, PrometheusRules

Namespace is hardcoded as `openshift-logging` on those objects (the ApplicationSet also creates/manages the namespace from `project.name`).

## Fill-in before merge

1. Replace `REPLACE_ME_CLUSTER` in `clusters.yaml` and `values.yaml` `envs[0].name` with the cluster key used in other `namespaces/*/clusters.yaml` files. Do not commit the filled cluster name back to this public kit.
2. Copy org annotations and AD edit/view groups from an existing namespace `values.yaml`. Do not invent group names.
3. Set `spec_hard` to match the LokiStack size. `limits.memory` **must** be
   set — the platform quota template defaults to 20Gi when absent.
   Set it to ~1.5–2× `requests.memory`. No `LimitRange` is used.

   | LokiStack size | `spec_hard` requests | `limits.memory` | Stack requests |
   |----------------|---------------------|-----------------|----------------|
   | `1x.extra-small` | cpu=30, memory=64Gi | 128Gi | 14 vCPU / 31 Gi |
   | `1x.small` | cpu=72, memory=176Gi | 256Gi | 34 vCPU / 67 Gi |
   | `1x.medium` | cpu=100, memory=256Gi | 384Gi | 54 vCPU / 139 Gi |

   Headroom above stack requests covers log collectors, Grafana, operators, and temporary extra pods during upgrades.

4. Keep `openshift.io/node-selector: ""`. Do not copy a dedicated-node selector from another namespace folder.

## ResourceQuota design

The quota enforces **requests** and sets a generous **limits.memory** ceiling.
There is no `LimitRange` in the namespace. The Loki Operator sets only
requests (not limits) on its pods, so they pass quota admission without any
LimitRange intervention. Pods without explicit limits are not charged against
the limits quota.

`limits.memory` **must** be present in `spec_hard` because the platform
namespace quota template defaults it to 20Gi when absent.

Previous iterations used a LimitRange to inject default limits, which caused:
- Injected limits conflicting with operator-set requests
- Massive quota inflation (14Gi per container x 14 pods = 196Gi of limits)
- Every LimitRange/quota adjustment required a PR through approval

## Operators in this folder

Both the Loki Operator and Cluster Logging Operator Subscriptions install into **`openshift-logging`**, with a single OperatorGroup named `openshift-logging`. That keeps every namespaced resource inside one Application destination.

This differs from the sandbox `make deploy` path, which puts the Loki Operator in `openshift-operators-redhat`. If OLM on the target cluster requires that namespace, move the Loki Subscription (and a dedicated OperatorGroup) there and confirm the ApplicationSet allows extra namespaces.

**Never create a second OperatorGroup** in `openshift-logging`. Check first:

```bash
oc get operatorgroup -n openshift-logging
```

`loki-operator` is published in **both** `redhat-operators` and `community-operators`. Unqualified `oc get packagemanifest loki-operator` returns the community package (default channel `alpha`). The Subscriptions in this folder already set `source: redhat-operators` — do not change that. Confirm the Red Hat package before merge:

```bash
oc get packagemanifest -n openshift-marketplace -l catalog=redhat-operators \
  -o jsonpath='{range .items[?(@.metadata.name=="loki-operator")].status.channels[*]}{.name}{"\n"}{end}'
```

If that is empty, the `redhat-operators` CatalogSource is missing or not READY. Re-enable it on OperatorHub; do not point the Subscription at community-operators.

## Out of band (not in git)

### Azure Blob secret

Create the Azure Blob secret before LokiStack can become Ready. Each LokiStack
needs its **own container**. Sharing a storage account across clusters is fine
when each stack has a unique container. Never point two stacks at the same
container.

```bash
oc create secret generic logging-loki-azure \
  -n openshift-logging \
  --from-literal=environment=AzureGlobal \
  --from-literal=account_name="${AZURE_STORAGE_ACCOUNT_NAME}" \
  --from-literal=account_key="${AZURE_STORAGE_ACCOUNT_KEY}" \
  --from-literal=container="${AZURE_CONTAINER_NAME}"
```

GitOps LokiStack uses `credentialMode: static`. The operator will only accept
the secret if it has `account_name`, `account_key`, `container`, and
`environment`. It does **not** accept `client_secret` (including on
`stable-6.6`). Workload ID (`token`) is the other supported mode when the
cluster actually has it. See [azure-blob-request.md](azure-blob-request.md).

### Service principal auth workaround

If the Azure storage account has `AllowSharedKeyAccess=false` and Workload
Identity Federation is not available, use SP auth:

1. Let the operator reconcile the LokiStack at least once (Managed)
2. Run `make init-sp-auth` which:
   - Creates the secret with SP credentials (`client_id`, `client_secret`, `tenant_id`)
   - Rewrites azure storage blocks in the live `logging-loki-config` ConfigMap
   - Switches LokiStack to `Unmanaged`
   - Restarts Loki pods

   If a later sync turns the stack back to `Managed`, the operator regenerates
   that ConfigMap. Run `make patch-loki-storage-config` after that reconcile
   to put the service principal values back. The rest of the operator config
   is left in place.

See `scripts/init-sp-auth.sh` and `gitops/namespaces/openshift-logging/loki-config-sp-overlay.yaml`.

**Revert path** (when shared key exception is approved):

```bash
# 1. Recreate secret with account_key
oc create secret generic logging-loki-azure -n openshift-logging \
  --from-literal=environment=AzureGlobal \
  --from-literal=account_name=<ACCOUNT> \
  --from-literal=account_key=<KEY> \
  --from-literal=container=loki-audit \
  --dry-run=client -o yaml | oc apply -f -

# 2. Switch to Managed (operator takes over)
oc patch lokistack logging-loki -n openshift-logging \
  --type merge -p '{"spec":{"managementState":"Managed"}}'

# 3. Delete the SP config overlay from gitops (ArgoCD syncs the deletion)
```

### Azure storage subnet ACL

If Loki pods cannot reach Azure Blob Storage, the ARO worker subnet may need
to be added to the storage account's network rules:

```bash
make add-storage-subnet
```

See `scripts/add-storage-subnet.sh` for details and manual fallback.

### Grafana

Grafana static resources (Deployment, Service, Route, RBAC, ConfigMaps) are
included in the sync at wave 5. After the sync completes, run:

```bash
make deploy-grafana
```

This creates the admin credentials Secret (from `GRAFANA_ADMIN_PASSWORD` in
`.env`) and injects bearer tokens into the datasource ConfigMap.

### Console plugin (UIPlugin)

The `UIPlugin` CR for the Console Logs tab is included in the sync at wave 5.
It requires the Cluster Observability Operator (COO) to be installed. If COO
is not present, the UIPlugin will remain pending but will not block the sync.

## Sync waves

| Wave | Resources |
|------|-----------|
| 1 | OperatorGroup, Subscriptions, namespace annotations from `values.yaml` |
| 2 | Collector ServiceAccount and ClusterRoleBindings |
| 3 | LokiStack (requires the Azure secret) |
| 4 | ClusterLogForwarder, SP Config Overlay (if SP auth) |
| 5 | Grafana (static), UIPlugin, PrometheusRules |

## What this folder does not include

- Azure account keys or a Secret manifest
- Grafana admin credentials or bearer tokens
- CatalogSource / ImageContentSourcePolicy (Red Hat operators from `openshift-marketplace`)
- MachineConfigPool / KubeletConfig

## Helm chart

`helm/audit-loki` remains for local `helm template` / `helm upgrade` and CI. It is not the Argo source for the copy-into-namespaces path. The default GitOps LokiStack is `1x.small` with **60-day** audit and infrastructure retention; adjust `lokistack.yaml` and `values.yaml` for production sizing.
