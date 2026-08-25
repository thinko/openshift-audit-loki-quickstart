#!/usr/bin/env bash
# Print install progress without exposing Azure keys.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_oc

log "API $(oc whoami --show-server 2>/dev/null || echo unknown)"
log "User $(oc whoami 2>/dev/null || echo unknown)"

echo
echo "== StorageClass =="
oc get storageclass managed-csi --no-headers 2>/dev/null && echo "managed-csi: present" || echo "managed-csi: MISSING (edit LokiStack storageClassName)"

echo
echo "== Operator CSVs =="
oc get csv -n "${OPERATORS_NAMESPACE}" 2>/dev/null || echo "(no CSVs in ${OPERATORS_NAMESPACE})"
oc get csv -n "${NAMESPACE}" 2>/dev/null || echo "(no CSVs in ${NAMESPACE})"

echo
echo "== CRDs =="
for crd in lokistacks.loki.grafana.com clusterlogforwarders.observability.openshift.io; do
  if oc get crd "${crd}" >/dev/null 2>&1; then
    echo "${crd}: present"
  else
    echo "${crd}: MISSING"
  fi
done

echo
echo "== Azure Blob secret ${NAMESPACE}/${SECRET_NAME} =="
if oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "keys:"
  list_secret_key_names | sed 's/^/  /'
  if azure_secret_has_required_keys; then
    echo "Loki keys: complete (values not printed)"
  else
    echo "Loki keys: INCOMPLETE (need account_name, account_key, container, environment)"
  fi
else
  echo "not found — LokiStack cannot start yet"
fi

echo
echo "== LokiStack / forwarder =="
oc get lokistack "${LOKISTACK_NAME}" -n "${LOKI_NAMESPACE}" 2>/dev/null || echo "LokiStack: not created"
oc get clusterlogforwarder "${CLF_NAME}" -n "${NAMESPACE}" 2>/dev/null || echo "ClusterLogForwarder: not created"

echo
echo "== Collector / Loki pods =="
oc get pods -n "${NAMESPACE}" 2>/dev/null || echo "(namespace ${NAMESPACE} missing)"
