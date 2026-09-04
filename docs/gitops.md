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
- Sibling **plain** YAML — OperatorGroup, Subscriptions, LokiStack, collector RBAC, ClusterLogForwarder, PrometheusRules

Namespace is hardcoded as `openshift-logging` on those objects (the ApplicationSet also creates/manages the namespace from `project.name`).

## Fill-in before merge

1. Replace `REPLACE_ME_CLUSTER` in `clusters.yaml` and `values.yaml` `envs[0].name` with the cluster key used in other `namespaces/*/clusters.yaml` files. Do not commit the filled cluster name back to this public kit.
2. Copy org annotations and AD edit/view groups from an existing namespace `values.yaml`. Do not invent group names.
3. Keep `spec_hard` at least **72 CPU / 176Gi**. LokiStack `1x.medium` requests about 54 vCPU / 139 Gi; a smaller quota will starve the stack. See [scaling-guide.md](scaling-guide.md).
4. Keep `openshift.io/node-selector: ""`. Do not copy a dedicated-node selector from another namespace folder.

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

Create the Azure Blob secret before LokiStack can become Ready. Each LokiStack
needs its **own container**. Sharing a storage account across clusters is fine
when each stack has a unique container. Never point two stacks at the same
container.

GitOps LokiStack uses `credentialMode: static`. The operator will only accept
the secret if it has `account_name`, `account_key`, `container`, and
`environment`. It does **not** accept `client_secret`. Workload ID (`token`)
is the other supported mode when the cluster actually has it. See
[azure-blob-request.md](azure-blob-request.md).

```bash
oc create secret generic logging-loki-azure \
  -n openshift-logging \
  --from-literal=environment=AzureGlobal \
  --from-literal=account_name="${AZURE_STORAGE_ACCOUNT_NAME}" \
  --from-literal=account_key="${AZURE_STORAGE_ACCOUNT_KEY}" \
  --from-literal=container="${AZURE_CONTAINER_NAME}"
```

After LokiStack is Ready:

```bash
make enable-console-plugin
```

Do **not** `oc apply -f manifests/05-enable-console-plugin.yaml` — that fragment replaces `spec.plugins` and disables other console plugins.

Grafana is not in the first GitOps sync (datasource tokens need ServiceAccounts that exist only after sync). Use `make deploy-grafana` afterward if needed.

## Sync waves

| Wave | Resources |
|------|-----------|
| 1 | OperatorGroup, Subscriptions, namespace annotations from `values.yaml` |
| 2 | Collector ServiceAccount and ClusterRoleBindings |
| 3 | LokiStack (requires the Azure secret) |
| 4 | ClusterLogForwarder |
| 5 | PrometheusRules |

## What this folder does not include

- Azure account keys or a Secret manifest
- Grafana Operator / instance / datasource tokens
- Console plugin patch
- CatalogSource / ImageContentSourcePolicy (Red Hat operators from `openshift-marketplace`)
- MachineConfigPool / KubeletConfig

## Helm chart

`helm/audit-loki` remains for local `helm template` / `helm upgrade` and CI. It is not the Argo source for the copy-into-namespaces path. The GitOps LokiStack is `1x.medium` with **60-day** audit and infrastructure retention.
