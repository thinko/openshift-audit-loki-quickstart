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
5. Omit CatalogSource, ImageContentSourcePolicy, MachineConfigPool, and
   KubeletConfig — those are for mirrored IBM catalogs / dedicated node pools,
   not Red Hat Loki.

Layout matches other multi-manifest namespace folders: ytt `values.yaml` plus
plain YAML siblings with the namespace hardcoded.

## Sync behaviour

The Loki Operator CRDs (`LokiStack`, `ClusterLogForwarder`) are installed by
OLM via the `Subscription` resources in wave 1. Because CRD registration is
asynchronous (OLM must pull the operator image and install its CSV), the first
sync will typically fail on the wave 3/4 resources with _"API could not find
LokiStack"_.

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
