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
4. **Secrets** — all deployment secrets live in a single Vault path
   (`secret/<team>/openshift/<cluster>/loki-storage`). Choose one:
   - **Vault (recommended):** populate `secrets.loki_storage.*` in `values.yaml`
     at render time from Vault. `storage-secret.yaml` and `grafana-secret.yaml`
     will template the K8s Secrets automatically.
   - **Out-of-band:** leave `secrets.loki_storage.account_name` empty and create
     `logging-loki-azure` manually (see [docs/gitops.md](../../../docs/gitops.md)).
     Leave `grafana_admin_password` empty and the PostSync hook will auto-generate one.
   Never commit actual credentials to `values.yaml`.
5. Confirm `spec_hard` in `values.yaml` matches the LokiStack size.
   `limits.memory` **must** be set — the platform `resourcequota.yaml`
   template defaults to 20Gi when absent, which blocks pod scheduling.
   Set it to ~1.5–2× `requests.memory`. Sizing reference:
   - `1x.extra-small`: requests cpu=30, memory=64Gi — limits.memory=128Gi
   - `1x.small`: requests cpu=72, memory=176Gi — limits.memory=256Gi
   - `1x.medium`: requests cpu=100, memory=256Gi — limits.memory=384Gi
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
| 2 | Storage Secret (from Vault, if `secrets.loki_storage` populated), Collector SA and ClusterRoleBindings |
| 3 | LokiStack (requires the Azure secret) |
| 4 | ClusterLogForwarder, SP Config Overlay (if SP auth) |
| 5 | Grafana (static), UIPlugin, PrometheusRules |

## Sync behaviour

The Loki Operator CRDs (`LokiStack`, `ClusterLogForwarder`) are installed by
OLM via the `Subscription` resources in wave 1. The `UIPlugin` CRD is not.
It comes from the Cluster Observability Operator, which is a separate
Application in `namespaces/openshift-cluster-observability-operator/`.
Because CRD registration is asynchronous (OLM must pull the operator
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

The `UIPlugin` CR registers the Logs tab in the OpenShift Console. The CRD
comes from the Cluster Observability Operator Application
(`namespaces/openshift-cluster-observability-operator/`), which must be
synced first. If that operator is absent, this CR stays pending and does
not block the rest of the sync.

### Service principal auth (AllowSharedKeyAccess=false)

If the cluster's Azure storage account has shared key access disabled and
Workload Identity Federation is not available, use SP auth:

```bash
make init-sp-auth
```

See `scripts/init-sp-auth.sh`. If a later sync turns the stack back to Managed,
run `make patch-loki-storage-config` after the operator rewrites
`logging-loki-config`.

### Azure storage subnet ACL

If Loki pods cannot reach Azure Blob Storage, the ARO worker subnet may be
missing from the storage account's network rules:

```bash
make add-storage-subnet
```

## ResourceQuota design

The quota enforces **requests** and sets a generous **limits.memory** ceiling.
The Loki Operator sets only requests (not limits) on its pods, so they pass
quota admission without any LimitRange intervention. We do **not** use a
LimitRange — pods without explicit limits are not charged against the
limits quota.

`limits.memory` **must** be present in `spec_hard` because the platform
namespace quota template defaults it to 20Gi when absent, which is far too
small for a LokiStack deployment and blocks pod scheduling. Set it to
~1.5–2× `requests.memory`.

Previous iterations used a LimitRange with default limits, which caused:
- Injected limits conflicting with operator-set requests
- Massive quota inflation (14Gi limit per container × 14 pods = 196Gi)
- Every adjustment required a PR through the approval process

## What this folder does not include

- Azure account keys or SP credentials (injected from Vault at render time,
  or created out-of-band). `storage-secret.yaml` and `grafana-secret.yaml`
  produce no output unless `secrets.loki_storage` values are populated.
- When Vault is not used: Grafana admin credentials are created by the PostSync
  hook (random password) or `deploy-grafana.sh`
- CatalogSource / ImageContentSourcePolicy
- MachineConfigPool / KubeletConfig
