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

## Post-sync Steps

- [ ] Deploy Grafana (bearer tokens + admin credentials):
  ```bash
  make deploy-grafana
  ```
- [ ] Verify UIPlugin registered: `oc get uiplugin logging`
- [ ] Verify Console Logs tab appears in OpenShift web console
- [ ] Verify Grafana datasources work: check Loki (Audit) and Prometheus

## Verification

- [ ] `oc get pods -n openshift-logging` — all pods Running
- [ ] `oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.status.conditions}'` — Ready=True
- [ ] Query audit logs in Grafana or Console: `{log_type="audit"} | json`
- [ ] Check alerts: `oc get prometheusrule loki-audit-alerts -n openshift-logging`
