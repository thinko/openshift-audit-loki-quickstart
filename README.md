# OpenShift audit LokiStack quickstart

Edge-filtered Kubernetes audit logs on Azure Red Hat OpenShift (ARO) / OpenShift 4.20, stored in a sandbox-sized `LokiStack` on Azure Blob.

Collectors (Vector, via `ClusterLogForwarder`) drop routine reads and platform service-account noise **before** the events leave the node. What remains — mutating API traffic with user attribution — is written to the in-cluster LokiStack and queried from **Observe → Logs → Audit**.

```text
  kube-apiserver / OpenShift API / OVN audit
                 |
                 v
        Vector (ClusterLogForwarder)
          kubeAPIAudit  +  drop filter
                 |
                 |  keep: create, update, patch, delete (and similar writes)
                 |  drop: get, list, watch
                 |  drop: system:node*, kube-system SAs, openshift-* SAs
                 v
           LokiStack 1x.extra-small
           Azure Blob  +  managed-csi PVCs
                 |
                 v
        OpenShift console logging-view-plugin
```

This repository is a **non-production evaluation profile**. `1x.extra-small` is the smallest supported production size (~100 GB/day) and is not highly available. Scale to `1x.small` or `1x.medium` before using the pattern on a production cluster.

## What you get

| Piece | Purpose |
| --- | --- |
| Loki Operator + Cluster Logging Operator (`stable-6.5`) | CRDs and controllers for OpenShift Logging 6.x |
| `LokiStack` `logging-loki` | Azure Blob object store, `managed-csi` for WAL/index PVCs, tenant mode `openshift-logging` |
| `ClusterLogForwarder` `audit` | Audit-only pipeline with edge filters |
| `logging-view-plugin` | Console **Observe → Logs** UI |

OpenShift 4.20 ships Logging **6.x**. The forwarder API is `observability.openshift.io/v1`. The older `logging.openshift.io/v1` `ClusterLogForwarder` is not used.

## Prerequisites

- OpenShift CLI (`oc`) logged in with **cluster-admin**
- OpenShift 4.20.x (ARO is the primary target; self-managed 4.20 works if you change `storageClassName`)
- Azure Storage Account + Blob container for Loki chunks/indexes
- Storage class `managed-csi` (default on ARO). On other clouds set `lokiStack.storageClassName` / edit `manifests/03-lokistack.yaml`
- Helm 3.x only if you install via the chart

Azure Blob can arrive later. Operators do not need it; LokiStack does.

Confirm the operator channel exists on your cluster:

```bash
oc get packagemanifest loki-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'
```

Both operators in this repo use `stable-6.5`. Change the channel in `manifests/01-loki-operator-subscription.yaml` or Helm `operator.channel` so Loki and Cluster Logging stay on the same minor version.

### Azure Blob

Do not reuse the ARO cluster or image-registry storage accounts. One Loki Blob
account per **environment type** (sandbox, dev, test, prod) is enough; use a
**unique container per cluster**. Never share a container across LokiStacks.

```bash
export AZURE_SUBSCRIPTION_ID='<subscription-guid>'   # optional if az account is already set
export AZURE_RESOURCE_GROUP='<resource-group>'
export AZURE_CONTAINER_NAME='loki-audit'             # unique per cluster if the account is shared
# optional: AZURE_STORAGE_ACCOUNT_NAME, AZURE_STORAGE_ACCOUNT_PREFIX (default lokiblob)

make azure-storage
set -a && source .env.azure && set +a
make deploy
```

`scripts/create-azure-storage.sh` creates a StorageV2 account (`Standard_LRS`,
TLS 1.2, public blob access off, hierarchical namespace off) in the resource
group's region and writes gitignored `.env.azure`. It does **not** create the
OpenShift secret; `make deploy` creates `logging-loki-azure`.

Alternatively set `AZURE_STORAGE_ACCOUNT_NAME`, `AZURE_STORAGE_ACCOUNT_KEY`,
and `AZURE_CONTAINER_NAME` yourself. For Entra Workload ID / CCO, omit the
account key and switch LokiStack `credentialMode` to `token-cco`.

See [docs/azure-blob-request.md](docs/azure-blob-request.md) for a paste-ready
request if a cloud team must create the account (do not reuse ARO cluster or
image-registry accounts; do not use `azure-cloud-credentials`).

If Blob is still pending:

```bash
make deploy-operators
make status
```

That installs namespaces, OperatorGroups, and the Loki + Cluster Logging
subscriptions, then stops. Re-run `make deploy` when the account or
`logging-loki-azure` secret exists.

Supported `environment` values: `AzureGlobal`, `AzureChinaCloud`, `AzureGermanCloud`, `AzureUSGovernment`.

## Quickstart (`make deploy`)

```bash
# after make azure-storage, or export the three Azure vars by hand
make deploy
```

`scripts/deploy.sh` will:

1. Create `openshift-operators-redhat` and `openshift-logging`
2. Subscribe to the Loki and Cluster Logging operators and wait for CRDs
3. Create secret `logging-loki-azure` from the environment (the key is never printed)
4. Apply `LokiStack` and wait until `Ready=True`
5. Apply collector RBAC **then** the `ClusterLogForwarder`
6. Append `logging-view-plugin` to `consoles.operator.openshift.io/cluster` without replacing other plugins

## Quickstart (Helm / GitOps)

Prefer an existing secret so credentials never land in Helm history:

```bash
oc create secret generic logging-loki-azure \
  -n openshift-logging \
  --from-literal=environment=AzureGlobal \
  --from-literal=account_name="${AZURE_STORAGE_ACCOUNT_NAME}" \
  --from-literal=account_key="${AZURE_STORAGE_ACCOUNT_KEY}" \
  --from-literal=container=loki-audit

helm upgrade --install audit-loki ./helm/audit-loki \
  --namespace openshift-logging \
  --set azure.existingSecret=logging-loki-azure
```

Or pass credentials with a **private** values file that is not committed:

```yaml
azure:
  accountName: exampleaccount
  accountKey: '***'
  container: loki-audit
```

```bash
helm upgrade --install audit-loki ./helm/audit-loki \
  --namespace openshift-logging \
  -f /secure/path/azure-values.yaml
```

Argo CD example (secret created out of band or via External Secrets):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: audit-loki
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/thinko/openshift-audit-loki-quickstart.git
    targetRevision: main
    path: helm/audit-loki
    helm:
      values: |
        azure:
          existingSecret: logging-loki-azure
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-logging
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
```

After Helm/Argo install, enable the console plugin:

```bash
make enable-console-plugin
```

Do **not** `oc apply -f manifests/05-enable-console-plugin.yaml`. That fragment would replace `spec.plugins` and disable every other console plugin.

## Verification

```bash
oc get csv -n openshift-operators-redhat
oc get csv -n openshift-logging
oc get lokistack logging-loki -n openshift-logging
oc get clusterlogforwarder audit -n openshift-logging
oc get pods -n openshift-logging
```

Expected: LokiStack `Ready=True`, forwarder conditions ready, collector DaemonSet pods `Running`.

### Console

1. Open the OpenShift web console
2. **Observe → Logs**
3. Tenant: **Audit** (not Application or Infrastructure)
4. Time range: last 15 minutes
5. Query: `{log_type="audit"} | json | verb="delete"`

### User attribution probe

```bash
make test-attribution
```

The script creates and deletes a ConfigMap named `audit-loki-probe-<timestamp>` and prints the exact LogQL plus the username `oc whoami` returned. Wait 30–90 seconds, run the query, and confirm `user.username` matches.

More queries: [docs/logql-queries.md](docs/logql-queries.md).

## Edge filter logic

Two filters run in order on the audit pipeline:

1. **`kubeAPIAudit`** — native kube-apiserver policy (wildcards, verbs). Drops `get`/`list`/`watch`, drops `system:node*`, `system:serviceaccount:kube-system:*`, and `system:serviceaccount:openshift-*`. Remaining events are stored at **Metadata** level (user, verb, `objectRef` — not request/response bodies).
2. **`drop-audit-noise`** — Vector drop filter:
   - `.verb` matches `^(get|list|watch)$`
   - `.user.username` matches `^system:(node|serviceaccount:kube-system|serviceaccount:openshift-.*)`

HTTP 401 and 403 are **kept** (default omit list is 404/409/422/429). Failed authentication and authorization remain queryable.

Application service accounts in non-`openshift-*` / non-`kube-system` namespaces are **not** dropped, so a compromised workload SA deleting a Secret still appears.

## Rollback

```bash
make destroy          # prompts; type destroy
# or
./scripts/destroy.sh --yes
```

This removes the forwarder, LokiStack, collector RBAC, and the Azure secret. It does **not** empty the Blob container. Operators and namespaces stay unless you pass `--purge-operators` / `--purge-namespaces` (the latter is only safe on a dedicated evaluation cluster).

Helm:

```bash
helm uninstall audit-loki --namespace openshift-logging
```

Console plugins are left as-is on destroy.

## Layout

```text
manifests/     oc apply path used by make deploy
helm/          parameterized chart for Helm / Argo CD
scripts/       deploy, operators-only, status, Azure bootstrap, destroy
docs/          LogQL cheat sheet and Azure Blob request fields
tests/         schema and leak checks (no live cluster required)
```

## Security notes

- Never commit a filled `02-storage-secret.yaml` or Helm values that contain `accountKey`
- Metadata-level audit still identifies **who** changed **what**; it does not store Secret data from request bodies
- `cluster-admin` is required to install operators and bind `collect-audit-logs`
- `1x.extra-small` replication is operator-managed and is not a multi-zone HA design

## License

Apache License 2.0. See [LICENSE](LICENSE).
