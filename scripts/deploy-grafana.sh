#!/usr/bin/env bash
# Deploy standalone Grafana with Loki + Prometheus datasources and dashboards.
# No Grafana Operator required — uses native Kubernetes Deployment + ConfigMaps.
# Idempotent: safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

GRAFANA_NAMESPACE="${NAMESPACE:-openshift-logging}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:latest}"

header "Standalone Grafana Deployment"

# ── Step 1: Apply RBAC (ServiceAccounts, ClusterRoles, ClusterRoleBindings) ──
echo "==> Applying RBAC and base resources..."
oc apply -f "${ROOT}/manifests/09-grafana-datasources.yaml"

# ── Step 2: Generate bearer tokens for datasources ──
echo "==> Generating Loki gateway bearer token..."
LOKI_TOKEN=$(oc create token grafana-loki -n "${GRAFANA_NAMESPACE}" --duration=8760h 2>/dev/null || echo "")
if [ -z "${LOKI_TOKEN}" ]; then
  err "Could not create token for grafana-loki SA. Check SA exists."
  exit 1
fi

echo "==> Generating Prometheus bearer token..."
PROM_TOKEN=$(oc create token grafana-prometheus -n "${GRAFANA_NAMESPACE}" --duration=8760h 2>/dev/null || echo "")
if [ -z "${PROM_TOKEN}" ]; then
  err "Could not create token for grafana-prometheus SA. Check SA exists."
  exit 1
fi

# ── Step 3: Patch datasource ConfigMap with actual tokens ──
echo "==> Injecting bearer tokens into datasource provisioning ConfigMap..."
DATASOURCE_YAML=$(oc get configmap grafana-datasource-provisioning \
  -n "${GRAFANA_NAMESPACE}" -o jsonpath='{.data.datasources\.yaml}')

DATASOURCE_YAML=$(echo "${DATASOURCE_YAML}" \
  | sed "s|\\\$LOKI_BEARER_TOKEN|Bearer ${LOKI_TOKEN}|g" \
  | sed "s|\\\$PROMETHEUS_BEARER_TOKEN|Bearer ${PROM_TOKEN}|g")

oc create configmap grafana-datasource-provisioning \
  -n "${GRAFANA_NAMESPACE}" \
  --from-literal="datasources.yaml=${DATASOURCE_YAML}" \
  --dry-run=client -o yaml | oc apply -f -

# ── Step 4: Create dashboards ConfigMap from JSON files ──
echo "==> Building dashboards ConfigMap from JSON files..."
DASHBOARD_ARGS=""
for dashboard_file in "${ROOT}"/dashboards/grafana-*.json; do
  [ -f "${dashboard_file}" ] || continue
  filename=$(basename "${dashboard_file}")
  echo "    Adding: ${filename}"
  DASHBOARD_ARGS="${DASHBOARD_ARGS} --from-file=${filename}=${dashboard_file}"
done

if [ -n "${DASHBOARD_ARGS}" ]; then
  eval oc create configmap grafana-dashboards \
    -n "${GRAFANA_NAMESPACE}" \
    ${DASHBOARD_ARGS} \
    --dry-run=client -o yaml | oc apply -f -
else
  echo "    WARN: No grafana-*.json files found in dashboards/"
fi

# ── Step 5: Set the image and apply the Deployment + Service + Route ──
echo "==> Applying Grafana Deployment (image: ${GRAFANA_IMAGE})..."
sed "s|image: grafana/grafana:latest|image: ${GRAFANA_IMAGE}|" \
  "${ROOT}/manifests/08-grafana-instance.yaml" | oc apply -f -

# ── Step 6: Wait for rollout ──
echo "==> Waiting for Grafana pod to become ready..."
oc rollout status deployment/loki-grafana -n "${GRAFANA_NAMESPACE}" --timeout=120s 2>/dev/null || \
  echo "    WARN: Grafana deployment not ready yet. Check: oc get pods -n ${GRAFANA_NAMESPACE} -l app=loki-grafana"

header "Grafana Deployment Complete"

ROUTE=$(oc get route loki-grafana -n "${GRAFANA_NAMESPACE}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "${ROUTE}" ]; then
  echo "Grafana URL: https://${ROUTE}"
  echo ""
  echo "Default credentials: admin / lokiAudit2026!"
  echo "(Change the password on first login)"
else
  echo "Route not yet available. Check: oc get route -n ${GRAFANA_NAMESPACE}"
fi

echo ""
echo "To use a custom image from Nexus, re-run with:"
echo "  GRAFANA_IMAGE=<nexus-host>/docker-hub/grafana/grafana:latest make deploy-grafana"
