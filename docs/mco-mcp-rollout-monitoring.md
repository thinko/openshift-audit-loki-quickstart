# Monitoring MachineConfig Rollouts via Loki

## Overview

MachineConfigPool (MCP) rollouts are node-level configuration changes
(OS updates, kubelet config, kernel args, etc.) coordinated by the
Machine Config Operator (MCO). This document covers how to monitor
rollouts using the LokiStack infrastructure and audit log pipelines.

## Key Components

| Component | Namespace | Role |
|-----------|-----------|------|
| `machine-config-operator` | `openshift-machine-config-operator` | Reconciles MachineConfig resources |
| `machine-config-controller` | `openshift-machine-config-operator` | Decides which nodes to update and in what order |
| `machine-config-daemon` (MCD) | `openshift-machine-config-operator` | DaemonSet pod on each node; applies config, drains, reboots |
| `machine-config-server` | `openshift-machine-config-operator` | Serves Ignition configs to nodes during boot |

## What Our CLF Filters Keep vs Drop

### Infrastructure Logs (primary source)

MCD and MCO pods generate infrastructure container logs routed through
the `infra-to-loki` pipeline. Our `drop-infra-noise` filter only
removes health probes, DNS lookups, kube-rbac-proxy TLS noise, leader
election, and token reviews. **MCD operational logs (draining, applying
config, rebooting) pass through cleanly.**

### Audit Logs (partial)

| Event | Kept? | Why |
|-------|-------|-----|
| Human `oc patch mcp worker ...` | Yes | Real user, mutation verb |
| Human `oc adm cordon <node>` | Yes | Real user, mutation verb |
| MCO patching node status | **No** | `system:serviceaccount:openshift-machine-config-operator:*` matches the system account drop rule |
| MCO updating MCP status | **No** | Same — system account dropped |

The MCO's own audit events are dropped because its service account
matches our `^system:serviceaccount:openshift-.*` filter. See
"Optional: MCO Audit Exception" below if full audit trail is needed.

## CLI Monitoring (Real-Time)

### Quick Status

```bash
oc get mcp
```

### Continuous Watch

```bash
oc get mcp -w
```

### Node-Level Detail

```bash
oc get nodes -o custom-columns=\
NAME:.metadata.name,\
READY:.status.conditions[-1:].status,\
MCD:.metadata.annotations.machineconfiguration\\.openshift\\.io/state,\
DESIRED:.metadata.annotations.machineconfiguration\\.openshift\\.io/desiredConfig,\
CURRENT:.metadata.annotations.machineconfiguration\\.openshift\\.io/currentConfig
```

### MCD Logs on a Specific Node

```bash
oc logs -n openshift-machine-config-operator \
  $(oc get pods -n openshift-machine-config-operator \
    -l k8s-app=machine-config-daemon \
    --field-selector spec.nodeName=<node-name> -o name) -f
```

### Events

```bash
oc get events -n openshift-machine-config-operator --sort-by=.lastTimestamp -w
```

### Combined Dashboard Loop

```bash
watch -n 10 'echo "=== MCP ===" && oc get mcp && echo && echo "=== Nodes ===" && oc get nodes -o wide'
```

## LogQL Queries (Loki / Grafana)

### MCD Activity on All Nodes

The primary rollout log — shows what each node's MCD is doing:

```logql
{log_type="infrastructure", kubernetes_namespace_name="openshift-machine-config-operator", kubernetes_container_name="machine-config-daemon"}
  | json message="message"
  | line_format "{{.kubernetes_host}}: {{.message}}"
```

### MCD State Transitions (drain / apply / reboot / done)

Filtered to the key lifecycle events:

```logql
{log_type="infrastructure", kubernetes_namespace_name="openshift-machine-config-operator", kubernetes_container_name="machine-config-daemon"}
  |~ "drain|cordon|uncordon|reboot|pivot|applying|completed|desired config"
  | json message="message"
  | line_format "{{.kubernetes_host}}: {{.message}}"
```

### MCO Controller Decisions

Which nodes are being updated, in what order, pool sync status:

```logql
{log_type="infrastructure", kubernetes_namespace_name="openshift-machine-config-operator", kubernetes_container_name="machine-config-controller"}
  |~ "pool|updating|updated|config|sync"
  | json message="message"
  | line_format "{{.message}}"
```

### Rollout Failures and Errors

Catch errors, degraded nodes, timeouts:

```logql
{log_type="infrastructure", kubernetes_namespace_name="openshift-machine-config-operator"}
  |~ "(?i)error|fail|degrad|timeout|unable"
  | json message="message"
  | line_format "{{.kubernetes_container_name}}/{{.kubernetes_host}}: {{.message}}"
```

### Human-Initiated MCP Audit Trail

Who triggered the rollout (human actions only, per current CLF rules):

```logql
{log_type="audit"}
  |~ "machineconfigpool|machineconfig"
  | json
  | verb=~"create|update|patch|delete"
  | line_format "{{.verb}} {{.objectRef_resource}}/{{.objectRef_name}} by {{.user_username}}"
```

### Node Drain Events

Pods being evicted during the rolling update:

```logql
{log_type="infrastructure", kubernetes_namespace_name="openshift-machine-config-operator", kubernetes_container_name="machine-config-daemon"}
  |~ "evict|drain|taint"
  | json message="message"
  | line_format "{{.kubernetes_host}}: {{.message}}"
```

## What to Look For

| Signal | Meaning |
|--------|---------|
| `UPDATING: True` in `oc get mcp` | Rollout in progress |
| `READYMACHINECOUNT` incrementing | Nodes finishing one by one |
| `DEGRADED: True` | A node failed to apply — investigate immediately |
| Node `SchedulingDisabled` | Currently draining before reboot |
| `desiredConfig != currentConfig` on a node | That node has not finished yet |

## Timing Expectations

The rollout proceeds one node at a time by default (`maxUnavailable: 1`).
Expect approximately 5-10 minutes per node for worker pools. Master pool
nodes roll one at a time regardless of `maxUnavailable`.

## Optional: MCO Audit Exception

To capture the MCO's own audit events (node patching, MCP status
updates), add a rule to the `kube-api-audit-policy` filter **before**
the system account drop rule. This adds moderate volume but provides a
complete audit trail of automated node operations.

```yaml
# In the kubeAPIAudit rules list, before the system account drop:
- level: Metadata
  users:
    - "system:serviceaccount:openshift-machine-config-operator:*"
  verbs:
    - update
    - patch
  resources:
    - group: ""
      resources:
        - nodes
    - group: machineconfiguration.openshift.io
      resources:
        - machineconfigpools
```

This would need to be added to both `manifests/04-clusterlogforwarder.yaml`
and `helm/audit-loki/templates/clusterlogforwarder.yaml`. Evaluate the
trade-off: extra audit volume vs complete rollout attribution.
