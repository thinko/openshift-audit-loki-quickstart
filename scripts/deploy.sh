#!/usr/bin/env bash
# Deploy the edge-filtered audit LokiStack stack onto the current oc context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [options]

Deploys Loki Operator + Cluster Logging Operator, an Azure-backed LokiStack
(1x.extra-small), an audit-only ClusterLogForwarder with edge filters, and
enables the OpenShift console logging-view-plugin.

Azure Blob is required for LokiStack (not for operator install):
  AZURE_STORAGE_ACCOUNT_NAME and AZURE_STORAGE_ACCOUNT_KEY
  or an existing Secret openshift-logging/logging-loki-azure with Loki keys.

Optional environment:
  AZURE_CONTAINER_NAME     Azure Blob container (default: loki-audit)
  AZURE_ENVIRONMENT        AzureGlobal | AzureChinaCloud | AzureGermanCloud | AzureUSGovernment
  SKIP_CONSOLE_PLUGIN      Set to 1 to skip patching the Console operator

Options:
  --operators-only  Namespaces, OperatorGroups, subscriptions, wait for CRDs; stop
                    before the Azure secret / LokiStack / forwarder
  --skip-wait       Do not wait for operators / LokiStack to become Ready
  --skip-console    Do not enable logging-view-plugin
  -h, --help        Show this help
EOF
}

SKIP_WAIT=0
SKIP_CONSOLE="${SKIP_CONSOLE_PLUGIN:-0}"
OPERATORS_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --operators-only) OPERATORS_ONLY=1; shift ;;
    --skip-wait) SKIP_WAIT=1; shift ;;
    --skip-console) SKIP_CONSOLE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_oc
require_cluster_admin

log "Using API $(oc whoami --show-server) / context $(oc config current-context 2>/dev/null || echo unknown)"

log "Applying namespaces"
oc apply -f "${ROOT}/manifests/00-namespace.yaml"

log "Pre-flight: checking OperatorGroups (OLM requires exactly one per namespace)"
ensure_single_operatorgroup "${OPERATORS_NAMESPACE}"
ensure_single_operatorgroup "${NAMESPACE}"

check_existing_clusterlogforwarders "${NAMESPACE}" || true

log "Applying operator subscriptions"
oc apply -f "${ROOT}/manifests/01-loki-operator-subscription.yaml"

if [[ "${SKIP_WAIT}" -eq 0 ]]; then
  wait_for_csv "${OPERATORS_NAMESPACE}"
  wait_for_csv "${NAMESPACE}"
  wait_for_crd lokistacks.loki.grafana.com
  wait_for_crd clusterlogforwarders.observability.openshift.io
fi

if [[ "${OPERATORS_ONLY}" -eq 1 ]]; then
  cat <<EOF

Operators submitted. LokiStack was not created (no object storage yet).

While waiting on the Blob account:
  * oc get csv -n ${OPERATORS_NAMESPACE}
  * oc get csv -n ${NAMESPACE}
  * oc get crd lokistacks.loki.grafana.com clusterlogforwarders.observability.openshift.io
  * oc get storageclass managed-csi
  * make status

Give the cloud team docs/azure-blob-request.md. When the account exists:

  export AZURE_STORAGE_ACCOUNT_NAME='...'
  export AZURE_STORAGE_ACCOUNT_KEY='...'
  export AZURE_CONTAINER_NAME='...'
  make deploy

If they create Secret ${NAMESPACE}/${SECRET_NAME} for you, just re-run make deploy.
EOF
  exit 0
fi

apply_azure_secret

log "Applying LokiStack"
oc apply -f "${ROOT}/manifests/03-lokistack.yaml"

if [[ "${SKIP_WAIT}" -eq 0 ]]; then
  wait_for_lokistack
fi

# RBAC first (same file as ClusterLogForwarder). Server-side apply is safe
# to re-run; creating the CLF before the bindings is not.
log "Applying collector RBAC and ClusterLogForwarder"
oc apply --server-side --field-manager=audit-loki-quickstart \
  -f "${ROOT}/manifests/04-clusterlogforwarder.yaml"

if [[ "${SKIP_CONSOLE}" -eq 0 ]]; then
  enable_console_plugin
else
  log "Skipping console plugin (requested)"
fi

cat <<EOF

Deploy submitted.

Next:
  1. oc get lokistack ${LOKISTACK_NAME} -n ${LOKI_NAMESPACE}
  2. oc get clusterlogforwarder ${CLF_NAME} -n ${NAMESPACE}
  3. oc get pods -n ${NAMESPACE}
  4. Open the console: Observe -> Logs -> tenant Audit
  5. ./scripts/test-attribution.sh

LogQL cheat sheet: docs/logql-queries.md
EOF
