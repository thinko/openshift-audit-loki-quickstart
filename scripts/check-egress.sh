#!/usr/bin/env bash
# Test network egress from the openshift-logging namespace to Azure Blob Storage.
# Runs a temporary pod that attempts HTTPS connections to the Azure Blob endpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_oc

PROBE_NS="${NAMESPACE}"
BLOB_HOST="${AZURE_BLOB_HOST:-blob.core.windows.net}"
PROBE_NAME="egress-probe-$(date -u +%s)"

log "Testing egress from ${PROBE_NS} to ${BLOB_HOST}"

cleanup() {
  oc delete pod "${PROBE_NAME}" -n "${PROBE_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

oc run "${PROBE_NAME}" \
  --namespace "${PROBE_NS}" \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --restart=Never \
  --rm \
  --attach \
  --timeout=60s \
  --command -- \
  sh -c "
    echo '--- DNS resolution ---'
    if getent hosts ${BLOB_HOST} >/dev/null 2>&1; then
      echo \"PASS: ${BLOB_HOST} resolves to \$(getent hosts ${BLOB_HOST} | head -1)\"
    else
      echo \"FAIL: cannot resolve ${BLOB_HOST}\"
      exit 1
    fi

    echo
    echo '--- HTTPS connectivity ---'
    if curl -sf --connect-timeout 10 --max-time 15 \
         -o /dev/null -w 'HTTP %{http_code} in %{time_total}s' \
         \"https://${BLOB_HOST}/\" 2>&1; then
      echo
      echo 'PASS: HTTPS connection succeeded'
    else
      echo 'FAIL: cannot reach https://${BLOB_HOST}/'
      echo 'Check egress NetworkPolicies and firewall rules.'
      exit 1
    fi

    echo
    echo '--- Azure Government endpoint (if applicable) ---'
    echo 'If using AzureUSGovernment, also test blob.core.usgovcloudapi.net'
    echo
    echo 'Egress check complete.'
  " 2>&1

log "Probe pod cleaned up"
