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
echo "== OperatorGroups =="
for ns in "${OPERATORS_NAMESPACE}" "${NAMESPACE}"; do
  og_count="$(oc get operatorgroup -n "${ns}" --no-headers 2>/dev/null | wc -l)"
  og_count="${og_count##* }"
  if (( og_count == 1 )); then
    og_name="$(oc get operatorgroup -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)"
    echo "${ns}: ${og_name} (OK)"
  elif (( og_count == 0 )); then
    echo "${ns}: NONE — run make deploy to create one"
  else
    echo "${ns}: WARNING — ${og_count} OperatorGroups (OLM requires exactly 1)"
    oc get operatorgroup -n "${ns}" --no-headers 2>/dev/null | sed 's/^/  /'
  fi
done

echo
echo "== Operator CSVs =="
for ns in "${OPERATORS_NAMESPACE}" "${NAMESPACE}"; do
  echo "--- ${ns} ---"
  oc get csv -n "${ns}" --no-headers 2>/dev/null | while IFS= read -r line; do
    phase="$(echo "${line}" | awk '{print $NF}')"
    if [[ "${phase}" == "Failed" ]]; then
      echo "  FAILED: ${line}"
    else
      echo "  ${line}"
    fi
  done
  if [[ -z "$(oc get csv -n "${ns}" --no-headers 2>/dev/null)" ]]; then
    echo "  (no CSVs)"
  fi
done

echo
echo "== Unapproved InstallPlans =="
unapproved_found=0
for ns in "${OPERATORS_NAMESPACE}" "${NAMESPACE}"; do
  unapproved="$(oc get installplan -n "${ns}" --no-headers 2>/dev/null \
    | awk '$3 == "Manual" && $4 == "false" {print $1, $2}')"
  if [[ -n "${unapproved}" ]]; then
    echo "${ns}:"
    echo "${unapproved}" | sed 's/^/  /'
    unapproved_found=1
  fi
done
if (( unapproved_found == 0 )); then
  echo "none (OK)"
fi

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
echo "== Existing ClusterLogForwarders =="
clf_list="$(oc get clusterlogforwarder.observability.openshift.io -n "${NAMESPACE}" --no-headers 2>/dev/null || true)"
if [[ -n "${clf_list}" ]]; then
  echo "${clf_list}" | while IFS= read -r line; do
    name="$(echo "${line}" | awk '{print $1}')"
    if [[ "${name}" == "${CLF_NAME}" ]]; then
      echo "  ${line}  <-- ours"
    else
      echo "  ${line}  (pre-existing)"
    fi
  done
else
  echo "  none"
fi

echo
echo "== LokiStack / forwarder =="
oc get lokistack "${LOKISTACK_NAME}" -n "${LOKI_NAMESPACE}" 2>/dev/null || echo "LokiStack: not created"
oc get clusterlogforwarder "${CLF_NAME}" -n "${NAMESPACE}" 2>/dev/null || echo "ClusterLogForwarder ${CLF_NAME}: not created"

echo
echo "== Collector / Loki pods =="
oc get pods -n "${NAMESPACE}" 2>/dev/null || echo "(namespace ${NAMESPACE} missing)"
