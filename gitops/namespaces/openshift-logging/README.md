# openshift-logging (GitOps handoff)

Copy this directory to `namespaces/openshift-logging/` in the internal
git repository that Argo CD already clones over SSH.

Do **not** point Argo at this public GitHub repo or at `helm/audit-loki`.
Sandbox installs still use `make deploy` from a laptop.

## Before the PR

1. Set `REPLACE_ME_CLUSTER` in `clusters.yaml` and `values.yaml` `envs[0].name`
   to the same cluster key other `namespaces/*/clusters.yaml` files use.
2. Copy org annotations and AD `rbac.edit` / `rbac.view` groups from an
   existing namespace folder. Leave `TBD` until those values are known.
3. Confirm `oc get operatorgroup -n openshift-logging` is empty (this folder
   creates one OperatorGroup). A second group breaks OLM.
4. Create secret `logging-loki-azure` in `openshift-logging` out of band
   (see [docs/gitops.md](../../../docs/gitops.md)). Never commit secrets.
5. Confirm `spec_hard` in `values.yaml` matches the LokiStack size. The
   quota enforces **requests only** (no limits section). Sizing reference:
   - `1x.extra-small`: cpu=30, memory=64Gi
   - `1x.small`: cpu=72, memory=176Gi
   - `1x.medium`: cpu=100, memory=256Gi
6. If the cluster has **infra nodes**, set `node_placement` in `values.yaml`:
   ```yaml
   node_placement:
     node_selector:
       node-role.kubernetes.io/infra: ""
     tolerations:
       - key: node-role.kubernetes.io/infra
         effect: NoSchedule
   ```
   This schedules all Loki components and Grafana on infra nodes.
   Log collector pods (DaemonSet) always run on ALL nodes regardless.
7. Omit CatalogSource, ImageContentSourcePolicy, MachineConfigPool, and
   KubeletConfig — those are for mirrored IBM catalogs / dedicated node pools,
   not Red Hat Loki.

Layout matches other multi-manifest namespace folders: ytt `values.yaml` plus
plain YAML siblings with the namespace hardcoded.

## Sync waves

| Wave | Resources |
|------|-----------|
| 1 | OperatorGroup, Subscriptions, namespace annotations from `values.yaml` |
| 2 | Collector ServiceAccount and ClusterRoleBindings |
| 3 | LokiStack (requires the Azure secret) |
| 4 | ClusterLogForwarder, SP Config Overlay (if SP auth) |
| 5 | Grafana (static), UIPlugin, PrometheusRules |

## Sync behaviour

The Loki Operator CRDs (`LokiStack`, `ClusterLogForwarder`) and the COO
CRDs (`UIPlugin`) are installed by OLM via the `Subscription` resources in
wave 1. Because CRD registration is asynchronous (OLM must pull the operator
image and install its CSV), the first sync will typically fail on the wave
3/4/5 resources with _"API could not find LokiStack"_.

These resources carry `SkipDryRunOnMissingResource=true` so ArgoCD won't
reject them during dry-run. Configure the Application with a **retry policy**
so it re-syncs automatically once the CRDs appear:

```yaml
spec:
  syncPolicy:
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
```

After the operator CSV reaches `Succeeded`, subsequent syncs will apply
cleanly on the first attempt.

## Post-sync steps

### Grafana

The Grafana Deployment, Service, Route, RBAC, and ConfigMap scaffolding are
included in the sync (wave 5). However, bearer tokens for the Loki and
Prometheus datasources must be created after the ServiceAccounts exist:

```bash
make deploy-grafana
```

This creates the `grafana-admin-credentials` Secret (from `GRAFANA_ADMIN_PASSWORD`
in `.env`) and injects bearer tokens into the datasource ConfigMap. Re-run
after token expiry or ServiceAccount recreation.

### UIPlugin

The `UIPlugin` CR registers the Logs tab in the OpenShift Console. It requires
the Cluster Observability Operator (COO) to be installed. If COO is not present,
the UIPlugin will remain in a pending state but will not block the sync.

### Service principal auth (AllowSharedKeyAccess=false)

If the cluster's Azure storage account has shared key access disabled and
Workload Identity Federation is not available, use SP auth:

```bash
make init-sp-auth
```

See `scripts/init-sp-auth.sh` and `loki-config-sp-overlay.yaml` for details.

### Azure storage subnet ACL

If Loki pods cannot reach Azure Blob Storage, the ARO worker subnet may be
missing from the storage account's network rules:

```bash
make add-storage-subnet
```

## ResourceQuota design

The quota enforces **requests only** — there is no `limits:` section. This
eliminates the need for a `LimitRange` to inject default limits. The Loki
Operator sets only requests (not limits) on its pods, so they pass quota
admission without any LimitRange intervention.

Previous iterations used a LimitRange with default limits, which caused:
- Injected limits conflicting with operator-set requests
- Massive quota inflation (14Gi limit per container x 14 pods = 196Gi)
- Every adjustment required a PR through the approval process

## What this folder does not include

- Azure account keys or a Secret manifest
- Grafana admin credentials Secret (created by `deploy-grafana.sh`)
- Grafana bearer tokens (created by `deploy-grafana.sh`)
- CatalogSource / ImageContentSourcePolicy
- MachineConfigPool / KubeletConfig
