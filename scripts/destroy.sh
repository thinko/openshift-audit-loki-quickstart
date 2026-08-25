#!/usr/bin/env bash
# Tear down the audit LokiStack stack from the current oc context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/destroy.sh [options]

Removes the ClusterLogForwarder, LokiStack, collector RBAC, and Azure secret
created by this repository. Azure Blob data is NOT deleted.

Options:
  --yes                 Skip the confirmation prompt
  --purge-operators     Also delete operator Subscriptions (CSVs remain until OLM garbage-collects)
  --purge-namespaces    Also delete openshift-logging and openshift-operators-redhat
                        (destructive — only use on a dedicated evaluation cluster)
  --keep-secret         Leave logging-loki-azure in place
  -h, --help            Show this help
EOF
}

ASSUME_YES=0
PURGE_OPERATORS=0
PURGE_NAMESPACES=0
KEEP_SECRET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    --purge-operators) PURGE_OPERATORS=1; shift ;;
    --purge-namespaces) PURGE_NAMESPACES=1; shift ;;
    --keep-secret) KEEP_SECRET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_oc
require_cluster_admin

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  cat <<EOF
This will delete from context $(oc config current-context 2>/dev/null || echo unknown):
  - ClusterLogForwarder/${CLF_NAME} in ${NAMESPACE}
  - LokiStack/${LOKISTACK_NAME} in ${LOKI_NAMESPACE}
  - collector ServiceAccount and ClusterRoleBindings
EOF
  [[ "${KEEP_SECRET}" -eq 1 ]] || echo "  - Secret/${SECRET_NAME}"
  [[ "${PURGE_OPERATORS}" -eq 1 ]] && echo "  - Loki and Cluster Logging operator Subscriptions"
  [[ "${PURGE_NAMESPACES}" -eq 1 ]] && echo "  - Namespaces ${NAMESPACE} and ${OPERATORS_NAMESPACE}"
  echo
  echo "Azure Blob contents are left intact."
  read -r -p "Type 'destroy' to continue: " answer
  [[ "${answer}" == "destroy" ]] || die "Aborted"
fi

delete_if_present() {
  local kind="$1"
  local name="$2"
  local ns="${3:-}"
  local ns_args=()
  [[ -n "${ns}" ]] && ns_args=(-n "${ns}")
  if oc get "${kind}" "${name}" "${ns_args[@]}" >/dev/null 2>&1; then
    log "Deleting ${kind}/${name} ${ns:+in ${ns}}"
    oc delete "${kind}" "${name}" "${ns_args[@]}" --wait=true --timeout=180s || \
      err "Failed to delete ${kind}/${name} (continuing)"
  else
    log "Not found: ${kind}/${name} ${ns:+in ${ns}}"
  fi
}

# Forwarder first so collectors stop writing, then the store.
delete_if_present clusterlogforwarder "${CLF_NAME}" "${NAMESPACE}"
delete_if_present lokistack "${LOKISTACK_NAME}" "${LOKI_NAMESPACE}"

delete_if_present clusterrolebinding logging-collector-audit-logs
delete_if_present clusterrolebinding logging-collector-logs-writer
delete_if_present serviceaccount "${COLLECTOR_SA}" "${NAMESPACE}"

if [[ "${KEEP_SECRET}" -ne 1 ]]; then
  delete_if_present secret "${SECRET_NAME}" "${NAMESPACE}"
fi

if [[ "${PURGE_OPERATORS}" -eq 1 ]]; then
  delete_if_present subscription loki-operator "${OPERATORS_NAMESPACE}"
  delete_if_present subscription cluster-logging "${NAMESPACE}"
  delete_if_present operatorgroup loki-operator "${OPERATORS_NAMESPACE}"
  delete_if_present operatorgroup cluster-logging "${NAMESPACE}"
fi

if [[ "${PURGE_NAMESPACES}" -eq 1 ]]; then
  err "Deleting namespaces ${NAMESPACE} and ${OPERATORS_NAMESPACE}"
  oc delete namespace "${NAMESPACE}" --wait=false || true
  oc delete namespace "${OPERATORS_NAMESPACE}" --wait=false || true
fi

log "Destroy complete. Console plugins were left unchanged."
log "To re-install: make deploy"
