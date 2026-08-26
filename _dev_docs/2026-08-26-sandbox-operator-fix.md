# Session: Sandbox cluster operator fix and prep

**Date**: 2026-08-26
**Participants**: Dhyan Patel (junior admin), consulting team
**Cluster**: ARO Sandbox (`REDACTED_CLUSTER.dev.REDACTED_DOMAIN.net:6443`)
**Context**: Operators deployed via `make deploy-operators` the previous day; Azure Blob storage account pending (ServiceNow ticket with Cloud Ops).

## Problem

`make status` showed `cluster-logging.v6.4.1` CSV in **Failed** phase, cycling
between Succeeded and Failed (ComponentUnhealthy). The loki-operator CSV was
healthy at v6.5.2.

## Root cause: duplicate OperatorGroups

The `openshift-logging` namespace had **two** OperatorGroups:

| Name | Age | Source |
|------|-----|--------|
| `cluster-logging` | 20h | Created by our `manifests/00-namespace.yaml` |
| `openshift-logging` | 412d | Pre-existing from the original logging install |

OLM requires exactly one OperatorGroup per namespace. With two present:
- OLM overrides `installPlanApproval: Automatic` to `Manual`
- The subscription status reported: `more than one operator group(s) are managing this namespace count=2`
- The cluster-logging-operator deployment could not stabilize
- The pending upgrade to v6.4.2 (InstallPlan `install-sbx76`) was blocked with `approved: false`

## Fix applied on cluster

```bash
oc delete operatorgroup cluster-logging -n openshift-logging
oc patch installplan install-sbx76 -n openshift-logging \
  --type merge -p '{"spec":{"approved":true}}'
```

OLM then walked the full upgrade chain:
**v6.2.3 -> v6.4.1 -> v6.4.2 -> v6.5.2 (Succeeded)**

Both operators converged to v6.5.2 on `stable-6.5`.

## Pre-existing logging stack discovery

The cluster already had a `ClusterLogForwarder` named `instance` (412d old),
forwarding **unfiltered** audit logs to **Azure Monitor Log Analytics**:

```yaml
outputs:
  - type: azureMonitor
    name: azure-monitor-audit
    customerId: 5e685811-bc5d-4e73-8b48-00700c300aa7
    logType: aro_audit_logs
pipelines:
  - inputRefs: [audit]
    outputRefs: [azure-monitor-audit]
```

**Decision**: Keep both CLFs running side by side. Our `loki-audit` CLF provides
edge-filtered audit logs to in-cluster LokiStack for operational debugging;
the existing `instance` CLF continues sending the full unfiltered stream to
Azure Monitor for compliance/retention. Trade-off: two Vector DaemonSets
(12 collector pods on 6 nodes).

## Other findings

- `custom-metrics-autoscaler.v2.19.0-1` CSV was also cycling Failed/Pending,
  but the actual KEDA pods were healthy (1/1 Running, 0 restarts). This is an
  OLM bookkeeping issue unrelated to our deployment.
- `cloud-native-postgresql.v1.30.0` (EDB) was also in Failed state — pre-existing,
  not ours.

## Repo changes made

1. **Removed static openshift-logging OperatorGroup** from `00-namespace.yaml`.
   `deploy.sh` now creates one dynamically only if none exists.
2. **Added pre-flight helpers** to `common.sh`: `ensure_single_operatorgroup()`,
   `check_failed_csvs()`, `check_unapproved_installplans()`,
   `check_existing_clusterlogforwarders()`.
3. **Improved `status.sh`** with OG counts, Failed CSV highlighting, unapproved
   InstallPlan detection, and existing CLF visibility.
4. **Renamed CLF** from `audit` to `loki-audit` to avoid ambiguity with the
   pre-existing `instance` CLF.
5. **Defaulted Helm `createOperatorGroups` to `false`** with guidance comment.
6. **Added `make preflight`** — read-only cluster validation.
7. **Added `make apply-rbac`** — pre-apply collector SA + CRBs without the CLF.
8. **Updated README** with "Clusters with an existing logging stack" section.

## Remaining work

- Azure Blob storage account creation (pending ServiceNow ticket)
- `make deploy` once Blob credentials are available
- Consider consolidating the two CLFs as a follow-up optimization
