#!/usr/bin/env bash
# Validate cluster readiness for a LokiStack deployment without changing anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_oc
require_cluster_admin

ERRORS=0
WARNINGS=0

pass()  { printf '  [PASS]  %s\n' "$*"; }
warn()  { printf '  [WARN]  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail()  { printf '  [FAIL]  %s\n' "$*"; ERRORS=$((ERRORS + 1)); }

log "Pre-flight check for LokiStack deployment"
log "API $(oc whoami --show-server) / User $(oc whoami)"

echo
echo "== Namespaces =="
for ns in "${OPERATORS_NAMESPACE}" "${NAMESPACE}"; do
  if oc get namespace "${ns}" >/dev/null 2>&1; then
    pass "${ns} exists"
  else
    warn "${ns} does not exist (will be created by make deploy)"
  fi
done

echo
echo "== OperatorGroups (must be exactly 1 per namespace) =="
for ns in "${OPERATORS_NAMESPACE}" "${NAMESPACE}"; do
  if ! oc get namespace "${ns}" >/dev/null 2>&1; then
    warn "${ns} does not exist yet — skipping OG check"
    continue
  fi
  og_count="$(oc get operatorgroup -n "${ns}" --no-headers 2>/dev/null | wc -l)"
  og_count="${og_count##* }"
  if (( og_count == 1 )); then
    og_name="$(oc get operatorgroup -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name)"
    pass "${ns}: 1 OperatorGroup (${og_name})"
  elif (( og_count == 0 )); then
    pass "${ns}: 0 OperatorGroups (deploy.sh will create one)"
  else
    fail "${ns}: ${og_count} OperatorGroups — OLM requires exactly 1"
    oc get operatorgroup -n "${ns}" --no-headers 2>/dev/null | sed 's/^/         /'
  fi
done

echo
echo "== StorageClass =="
if oc get storageclass managed-csi >/dev/null 2>&1; then
  pass "managed-csi is available"
else
  fail "managed-csi StorageClass not found (edit LokiStack storageClassName)"
fi

echo
echo "== Operator catalog =="
for pkg in loki-operator cluster-logging; do
  if oc get packagemanifest "${pkg}" -n openshift-marketplace >/dev/null 2>&1; then
    channel_csv="$(oc get packagemanifest "${pkg}" -n openshift-marketplace \
      -o jsonpath='{range .status.channels[?(@.name=="stable-6.5")]}{.currentCSV}{end}' 2>/dev/null)"
    if [[ -n "${channel_csv}" ]]; then
      pass "${pkg}: stable-6.5 -> ${channel_csv}"
    else
      fail "${pkg}: stable-6.5 channel not found in catalog"
    fi
  else
    fail "${pkg}: package manifest not in openshift-marketplace"
  fi
done

echo
echo "== Existing CSVs =="
for ns in "${OPERATORS_NAMESPACE}" "${NAMESPACE}"; do
  if ! oc get namespace "${ns}" >/dev/null 2>&1; then
    continue
  fi
  failed="$(oc get csv -n "${ns}" --no-headers 2>/dev/null | awk '$NF == "Failed" {print $1}')"
  if [[ -n "${failed}" ]]; then
    fail "Failed CSVs in ${ns}:"
    echo "${failed}" | sed 's/^/         /'
  else
    pass "No Failed CSVs in ${ns}"
  fi
done

echo
echo "== Unapproved InstallPlans =="
for ns in "${OPERATORS_NAMESPACE}" "${NAMESPACE}"; do
  if ! oc get namespace "${ns}" >/dev/null 2>&1; then
    continue
  fi
  unapproved="$(oc get installplan -n "${ns}" --no-headers 2>/dev/null \
    | awk '$3 == "Manual" && $4 == "false" {print $1, $2}')"
  if [[ -n "${unapproved}" ]]; then
    fail "Unapproved InstallPlans in ${ns}:"
    echo "${unapproved}" | sed 's/^/         /'
  else
    pass "No blocked InstallPlans in ${ns}"
  fi
done

echo
echo "== Existing ClusterLogForwarders =="
if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  clf_count="$(oc get clusterlogforwarder.observability.openshift.io -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)"
  clf_count="${clf_count##* }"
  if (( clf_count == 0 )); then
    pass "No existing CLFs in ${NAMESPACE}"
  else
    warn "${clf_count} existing CLF(s) — our ${CLF_NAME} will run alongside them"
    oc get clusterlogforwarder.observability.openshift.io -n "${NAMESPACE}" --no-headers 2>/dev/null | sed 's/^/         /'
  fi
fi

echo
echo "== Azure Blob secret =="
if oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  if azure_secret_has_required_keys; then
    pass "${NAMESPACE}/${SECRET_NAME} exists with required keys"
  else
    warn "${NAMESPACE}/${SECRET_NAME} exists but is missing keys"
  fi
else
  warn "${NAMESPACE}/${SECRET_NAME} not found — needed before make deploy (not for make deploy-operators)"
fi

echo
echo "=========================================="
printf "Results: %d errors, %d warnings\n" "${ERRORS}" "${WARNINGS}"
if (( ERRORS > 0 )); then
  echo "Fix the errors above before running make deploy."
  exit 1
fi
if (( WARNINGS > 0 )); then
  echo "Warnings are informational — deploy can proceed."
fi
echo "=========================================="
