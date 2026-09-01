#!/usr/bin/env bash
# Deploy the Grafana Operator, instance, datasources, and dashboards.
# Idempotent: safe to re-run. Waits for the operator CSV before applying CRs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

GRAFANA_NAMESPACE="${NAMESPACE:-openshift-logging}"
OPERATOR_NAMESPACE="openshift-operators"
TIMEOUT="${GRAFANA_TIMEOUT:-300}"

ensure_bearer_token_secret() {
  local sa="$1"
  local secret_name="$2"
  if oc get secret "${secret_name}" -n "${GRAFANA_NAMESPACE}" &>/dev/null; then
    echo "    ${secret_name} already exists"
    return 0
  fi
  local token
  token="$(oc create token "${sa}" -n "${GRAFANA_NAMESPACE}" --duration=8760h 2>/dev/null || echo "")"
  if [ -z "${token}" ]; then
    echo "    WARN: Could not create token for SA ${sa}. Re-run after the SA is ready."
    return 0
  fi
  oc create secret generic "${secret_name}" \
    -n "${GRAFANA_NAMESPACE}" \
    --from-literal=token="Bearer ${token}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "    Created ${secret_name}"
}

loki_datasource_for_dashboard() {
  case "$1" in
    grafana-infra-health) echo "Loki-Infrastructure" ;;
    *) echo "Loki" ;;
  esac
}

header "Deploying Grafana Operator"

echo "==> Installing Grafana Operator Subscription..."
oc apply -f "${ROOT}/manifests/07-grafana-operator.yaml"

echo "==> Waiting for Grafana Operator CSV (timeout: ${TIMEOUT}s)..."
end_time=$((SECONDS + TIMEOUT))
csv_phase=""
while [ $SECONDS -lt $end_time ]; do
  csv_phase=$(oc get csv -n "${OPERATOR_NAMESPACE}" \
    -l operators.coreos.com/grafana-operator.openshift-operators="" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  if [ "${csv_phase}" = "Succeeded" ]; then
    echo "    Grafana Operator CSV is Succeeded"
    break
  fi
  echo "    CSV phase: ${csv_phase:-Pending}... waiting"
  sleep 10
done

if [ "${csv_phase}" != "Succeeded" ]; then
  echo "ERROR: Grafana Operator CSV did not reach Succeeded within ${TIMEOUT}s" >&2
  echo "       Check: oc get csv -n ${OPERATOR_NAMESPACE} | grep grafana" >&2
  exit 1
fi

echo "==> Waiting for Grafana CRD..."
oc wait --for=condition=Established crd/grafanas.grafana.integreatly.org --timeout=60s

header "Deploying Grafana Instance"

echo "==> Applying Grafana instance..."
oc apply -f "${ROOT}/manifests/08-grafana-instance.yaml"

echo "==> Applying datasource CRs and query RBAC..."
oc apply -f "${ROOT}/manifests/09-grafana-datasources.yaml"

echo "==> Creating gateway / Prometheus bearer token secrets..."
ensure_bearer_token_secret grafana-prometheus grafana-prometheus-token
ensure_bearer_token_secret grafana-loki grafana-loki-gateway-token

echo "==> Waiting for Grafana pod..."
oc wait --for=condition=Available deployment/loki-grafana-deployment \
  -n "${GRAFANA_NAMESPACE}" --timeout=180s 2>/dev/null || \
  echo "    WARN: Grafana deployment not ready yet. Dashboards will apply once it starts."

header "Deploying Dashboards"

echo "==> Creating GrafanaDashboard CRs from JSON files..."
for dashboard_file in "${ROOT}"/dashboards/grafana-*.json; do
  [ -f "${dashboard_file}" ] || continue
  dashboard_name=$(basename "${dashboard_file}" .json)
  loki_ds="$(loki_datasource_for_dashboard "${dashboard_name}")"
  echo "    Applying dashboard: ${dashboard_name} (DS_LOKI -> ${loki_ds})"
  cat <<EOF | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: ${dashboard_name}
  namespace: ${GRAFANA_NAMESPACE}
  labels:
    app.kubernetes.io/name: loki-grafana
    app.kubernetes.io/part-of: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  instanceSelector:
    matchLabels:
      dashboards: "loki-audit"
  datasources:
    - inputName: DS_LOKI
      datasourceName: ${loki_ds}
    - inputName: DS_PROMETHEUS
      datasourceName: Prometheus
  json: |
$(sed 's/^/    /' "${dashboard_file}")
EOF
done

header "Grafana Deployment Complete"

ROUTE=$(oc get route -n "${GRAFANA_NAMESPACE}" -l app.kubernetes.io/name=loki-grafana \
  -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
if [ -n "${ROUTE}" ]; then
  echo "Grafana URL: https://${ROUTE}"
  echo ""
  echo "Admin credentials:"
  echo "  oc get secret loki-grafana-admin-credentials -n ${GRAFANA_NAMESPACE} \\"
  echo "    -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d && echo"
else
  echo "Route not yet available. Check: oc get route -n ${GRAFANA_NAMESPACE}"
fi
