# Cluster Observability Operator

Copy this directory to `namespaces/openshift-cluster-observability-operator/`
in the internal git repository. The namespace ApplicationSet then creates a
**separate** Application whose destination is this namespace.

Do not add these objects to `namespaces/openshift-logging/`. That namespace
already has an OperatorGroup, and a second one breaks OLM.

Sync this Application before the logging `UIPlugin`. The operator publishes
the `UIPlugin` CRD. The logging folder only contains the custom resource.

## Before the PR

1. Set `REPLACE_ME_CLUSTER` in `clusters.yaml` and `values.yaml` `envs[0].name`
   to the same cluster key as the logging folder.
2. Copy AD `rbac.edit` / `rbac.view` groups from an existing namespace folder.
3. Confirm the `stable` channel exists:

   ```bash
   oc get packagemanifest cluster-observability-operator -n openshift-marketplace \
     -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'
   ```

4. Confirm there is no existing Subscription:

   ```bash
   oc get subscription cluster-observability-operator -A
   ```

The OperatorGroup targets only this namespace so it does not collide with the
AllNamespaces group in `openshift-operators`. The `UIPlugin` CRD is still
cluster-scoped after the CSV installs.
