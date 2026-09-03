# LokiStack Scaling & Environment Sizing Guide

## LokiStack Size Profiles

Red Hat's LokiStack operator provides fixed size profiles. The `1x` prefix
is the instance count (fixed at 1) and the suffix determines capacity.

| Size | Ingest Rate | QPS | CPU | Memory | Disk | Target Environment |
|------|------------|-----|-----|--------|------|--------------------|
| `1x.pico` | 50 GB/day | 1-25 | 7 vCPU | 17 Gi | 590 Gi | SNO / edge |
| `1x.extra-small` | 100 GB/day | 1-25 | 14 vCPU | 31 Gi | 430 Gi | Sandbox (≤10 nodes) |
| `1x.small` | 500 GB/day | 25-50 | 34 vCPU | 67 Gi | 430 Gi | Test (10-30 nodes) |
| `1x.medium` | 2 TB/day | 25-75 | 54 vCPU | 139 Gi | 590 Gi | Prod (30+ nodes) |

> **Note**: CPU/memory are *total requests* across all Loki components
> (ingester, querier, compactor, distributor, gateway, index-gateway,
> query-frontend). Actual node footprint depends on `LimitRange` and
> over-commit settings.

## Environment Overlay Strategy

Each environment uses a base `values.yaml` plus an environment-specific
overlay that scales the LokiStack and adjusts limits:

```bash
# Sandbox (current)
helm upgrade --install audit-loki ./helm/audit-loki \
  -f helm/audit-loki/values.yaml \
  -f helm/audit-loki/values-sandbox.yaml

# Test
helm upgrade --install audit-loki ./helm/audit-loki \
  -f helm/audit-loki/values.yaml \
  -f helm/audit-loki/values-test.yaml

# Production
helm upgrade --install audit-loki ./helm/audit-loki \
  -f helm/audit-loki/values.yaml \
  -f helm/audit-loki/values-prod.yaml
```

## What Scales Between Environments

| Component | Sandbox | Test | Prod |
|-----------|---------|------|------|
| LokiStack size | `1x.extra-small` | `1x.small` | `1x.medium` |
| Querier memory | ~4 Gi | ~8 Gi | ~16 Gi |
| Ingester replicas | 3 | 3 | 3 |
| Audit retention | 14 days | 30 days | 90 days |
| Infra retention | 7 days | 14 days | 30 days |
| Max entries/query | 5,000 | 10,000 | 20,000 |
| Max query series | 500 | 1,000 | 2,000 |
| Ingestion rate | 4 MB/s | 8 MB/s | 16 MB/s |

## Query Limits (Why They Matter)

Without query limits, a single dashboard panel requesting 6 hours of
infrastructure logs across all `openshift-*` namespaces can cause the
querier to allocate 2+ GiB of memory, OOM, and restart — taking down
all other queries with it.

The `maxEntriesLimitPerQuery` cap ensures no single query can return
more than N log lines, forcing users to narrow their time range or
add filters. The `maxQuerySeries` cap limits the number of distinct
label combinations in metric queries.

## Grafana Datasource Tuning

The Grafana datasource config also has query guards:

| Setting | Sandbox | Test/Prod |
|---------|---------|-----------|
| `maxLines` | 500 | 1000 |
| `timeout` | 60s | 120s |
| `dataproxy.timeout` | 60s | 120s |

These should scale proportionally with the LokiStack size.

## Dashboard Query Design Principles

1. **Always use `|~` or `|=` pre-filters** before `| json` — Loki can
   skip entire chunks that don't match the literal string
2. **Use selective JSON extraction** (`| json field="key"`) instead of
   bare `| json` which parses all 50+ Viaq fields
3. **Use fixed-width buckets** (`[5m]`, `[15m]`) for `count_over_time`
   rather than `$__interval` which may not resolve in all versions
4. **Scope namespace selectors** — avoid `kubernetes_namespace_name=~".*"`
   when a specific namespace or list will do
5. **Default dashboards to 1h** — users can extend, but the default
   should be safe for the smallest LokiStack profile

## Storage Account Sizing

Azure Blob Storage costs scale with retention and ingest volume:

| Environment | Daily Ingest | Retention | Estimated Storage |
|-------------|-------------|-----------|-------------------|
| Sandbox | ~10-50 GB | 7-14 days | 100-700 GB |
| Test | ~50-200 GB | 14-30 days | 700 GB - 6 TB |
| Prod | ~200 GB-2 TB | 30-90 days | 6-180 TB |

Use Azure Lifecycle Management policies to automatically tier or delete
objects past the retention window as a safety net.

## Alerting

### Alert Categories

Alerts are split into two groups that avoid duplicating built-in OCP alerts:

| Group | Alerts | Purpose |
|-------|--------|---------|
| `lokistack-health` | LokiIngesterNotReady, LokiQuerierNotReady, LokiCompactorNotReady, LokiHighRequestErrorRate, LokiPVCNearlyFull, LokiComponentRestarting | Detects Loki component failures, disk pressure, and crash loops |
| `audit-pipeline-health` | AuditLogIngestionStopped, InfraLogIngestionStopped, AuditFilterEffectivenessLow, AuditIngestionSpike | Detects pipeline breaks, filter drift, and unusual activity |

### Threshold Scaling

| Threshold | Sandbox | Test | Prod | Why |
|-----------|---------|------|------|-----|
| `componentNotReadyFor` | 10m | 5m | 5m | Sandbox has fewer resources, slower recovery |
| `errorRatePercent` | 10% | 5% | 3% | Tighter in prod where reliability matters |
| `pvcUsagePercent` | 85% | 85% | 80% | Earlier warning in prod for capacity planning |
| `ingestionStoppedFor` | 30m | 15m | 10m | Faster detection in prod |
| `ingestionSpikeMultiplier` | 3x | 3x | 2x | Lower threshold catches anomalies sooner in prod |

### Notification Routing

The `AlertmanagerConfig` resource is disabled by default. To enable:

1. Set `alerting.receiver.enabled: true` in the environment values file
2. Configure `alerting.receiver.webhookUrl` with a PagerDuty, Slack, or
   Teams webhook endpoint
3. Deploy with `make deploy-alerting` or via Helm upgrade

Critical alerts (severity=critical) repeat at `criticalRepeatInterval`
(default 1h); warnings repeat at `repeatInterval` (default 4h).

### Avoiding Duplicate Alerts

The following alert types are already covered by built-in OCP monitoring
and should NOT be added to our PrometheusRule:

- `KubeDeploymentReplicasMismatch` — covers general deployment health
- `KubeContainerWaiting` — covers stuck containers
- `KubePodNotReady` — covers pod readiness
- `KubeDeploymentRolloutStuck` — covers rollout failures
- `KubePodCrashLooping` — covers crash loops (our `LokiComponentRestarting`
  is Loki-specific with a different threshold)

## Pre-deployment Checklist

Before deploying to a new environment:

1. **Verify node capacity**: `oc adm top nodes` — ensure headroom for
   the LokiStack CPU/memory requests listed above
2. **Verify storage class**: `oc get sc` — `managed-csi` (or equivalent)
   must support `ReadWriteOnce` for ingester WAL and compactor PVCs
3. **Verify Azure Blob access**: `make check-egress` and confirm the
   storage account + container are provisioned
4. **Verify Azure auth method**: Shared key, service principal, or
   workload identity — see `docs/azure-blob-request.md`
5. **Run preflight**: `make preflight` to validate operators, RBAC, and
   network connectivity
