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
   (see [docs/gitops.md](../../../docs/gitops.md)). Never commit keys.
5. Omit CatalogSource, ImageContentSourcePolicy, MachineConfigPool, and
   KubeletConfig — those are for mirrored IBM catalogs / dedicated node pools,
   not Red Hat Loki.

Layout matches other multi-manifest namespace folders: ytt `values.yaml` plus
plain YAML siblings with the namespace hardcoded.
