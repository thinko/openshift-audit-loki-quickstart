# Deployment Checklist: REPLACE_ME_CLUSTER

## Pre-deployment

- [ ] Verify cluster access: `oc whoami` shows cluster-admin user
- [ ] Verify no existing OperatorGroup: `oc get operatorgroup -n openshift-logging`
- [ ] Verify storage class: `oc get sc managed-csi`
- [ ] Verify Red Hat operators catalog: `oc get packagemanifest loki-operator -l catalog=redhat-operators`

## Azure Setup

- [ ] Storage account created: `AZURE_STORAGE_ACCOUNT_NAME`
- [ ] Blob container created on the environment account (do not create a new account per cluster):
  ```bash
  make azure-container
  # or: scripts/create-azure-container.sh --name <account> --cluster REPLACE_ME_CLUSTER
  ```
- [ ] Worker subnet added to storage account ACL:
  ```bash
  scripts/add-storage-subnet.sh --cluster REPLACE_ME_CLUSTER --account-name <storage-account>
  ```

## Secret Creation (out-of-band, before ArgoCD sync)

### Standard auth (account key)
```bash
oc create secret generic logging-loki-azure \
  -n openshift-logging \
  --from-literal=environment=AzureGlobal \
  --from-literal=account_name=<ACCOUNT_NAME> \
  --from-literal=account_key=<ACCOUNT_KEY> \
  --from-literal=container=REPLACE_ME_CLUSTER-audit-loki
```

### SP auth (AllowSharedKeyAccess=false)
```bash
# Set vars in .env first, then:
make init-sp-auth
```

## ArgoCD Sync

- [ ] Copy manifests to internal repo: `scripts/sync-gitops-to-internal.sh <overlay> <target>`
- [ ] Open PR, get peer review, merge
- [ ] ArgoCD syncs (may take 2-3 retries for CRDs to register)
- [ ] Verify: `oc get lokistack logging-loki -n openshift-logging`

## SP Auth — Vault / ArgoCD / Operator Sequence

> **Order matters.** If ArgoCD has `selfHeal: true`, any live patch to the
> LokiStack will be reverted within minutes unless git/Vault agree.

1. **Set `management_state=Unmanaged` in Vault** for this cluster:
   ```bash
   safe set secret/<team>/openshift/REPLACE_ME_CLUSTER/loki-storage \
     management_state=Unmanaged \
     ... (all other keys)
   ```
2. **Patch `gitops-secrets`** so the Conjur sidecar's cached `secrets.yaml`
   matches Vault immediately (otherwise wait for the next Conjur refresh):
   ```bash
   oc get secret gitops-secrets -n openshift-gitops -o json \
     | jq '.data["secrets.yaml"] |= (
         @base64d
         | gsub("management_state: \"Managed\""; "management_state: Unmanaged")
         | gsub("management_state: Managed"; "management_state: Unmanaged")
         | @base64
       )' | oc apply -f -
   ```
3. **Restart the repo-server** so the Conjur sidecar re-reads `gitops-secrets`
   (the sidecar only reads at pod startup, not on every render):
   ```bash
   oc rollout restart deployment/openshift-gitops-repo-server -n openshift-gitops
   oc rollout status deployment/openshift-gitops-repo-server -n openshift-gitops --timeout=120s
   ```
4. **Hard Refresh + Sync** in the ArgoCD UI (not just Refresh — Hard Refresh
   forces a re-render through the ytt/Conjur sidecar)
5. **Verify** the LokiStack is Unmanaged:
   ```bash
   oc get lokistack logging-loki -n openshift-logging \
     -o jsonpath='live={.spec.managementState}{"\n"}'
   ```
6. **Then** run `scripts/patch-loki-storage-config.sh` — the guard will
   confirm gitops-secrets says Unmanaged before proceeding.

> **Why this order?** The `patch-loki-storage-config.sh` script sets the
> LokiStack to Unmanaged and patches the ConfigMap. But if ArgoCD's
> desired manifest still renders `Managed`, self-heal reverts the
> LokiStack within minutes and the operator regenerates the ConfigMap,
> wiping the SP auth.

## COO (Cluster Observability Operator)

- [ ] COO app synced in its own namespace (`openshift-cluster-observability-operator`)
- [ ] CSV is `Succeeded`: `oc get csv -n openshift-cluster-observability-operator`
- [ ] If CSV shows `UnsupportedOperatorGroup`, the OperatorGroup must be AllNamespaces (no `targetNamespaces`)
- [ ] The OCP PSA label syncer will reset `pod-security` labels to `restricted` — do not fight it;
      add `ignoreDifferences` for the namespace pod-security labels in the Application
- [ ] ConsolePlugin enabled: `oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'`
- [ ] If the `logging` endpoint is `<none>`, restart the observability-operator pod and/or delete + let OLM reinstall the CSV

## Post-sync Steps

- [ ] Deploy Grafana (bearer tokens + admin credentials):
  ```bash
  make deploy-grafana
  ```
- [ ] Verify UIPlugin registered: `oc get uiplugin logging`
- [ ] Verify Console Logs tab appears in OpenShift web console (may need `oc rollout restart deployment/console -n openshift-console` + browser hard-refresh)
- [ ] Verify Grafana datasources work: check Loki (Audit) and Prometheus

## Verification

- [ ] `oc get pods -n openshift-logging` — all pods Running
- [ ] Both ingesters Running (1x.small needs 2 for replication_factor=2):
      `oc get pods -n openshift-logging -l app.kubernetes.io/component=ingester`
- [ ] `oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.status.conditions}'` — Ready=True
- [ ] No `LokiStackWriteRequestErrors` or `LokiIngesterFlushFailureRateCritical` alerts firing
- [ ] Query audit logs in Grafana or Console: `{log_type="audit"} | json`
- [ ] Check alerts: `oc get prometheusrule loki-audit-alerts -n openshift-logging`
