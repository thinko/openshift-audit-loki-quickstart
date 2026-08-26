#!/usr/bin/env bash
# Test network egress from the openshift-logging namespace to Azure Blob Storage.
# Creates a temporary pod, waits for it to complete, prints results, then cleans up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_oc

PROBE_NS="${NAMESPACE}"
BLOB_HOST="${AZURE_BLOB_HOST:-blob.core.windows.net}"
PROBE_NAME="egress-probe-$(date -u +%s)"
TIMEOUT=90

cleanup() {
  oc delete pod "${PROBE_NAME}" -n "${PROBE_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Testing egress from ${PROBE_NS} to ${BLOB_HOST}"

oc apply -n "${PROBE_NS}" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_NAME}
  labels:
    app: egress-probe
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  containers:
    - name: probe
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command:
        - sh
        - -c
        - |
          echo "=== DNS resolution ==="
          if getent hosts ${BLOB_HOST} >/dev/null 2>&1; then
            resolved=\$(getent hosts ${BLOB_HOST} | head -1)
            echo "PASS: ${BLOB_HOST} resolves to \${resolved}"
          else
            echo "FAIL: cannot resolve ${BLOB_HOST}"
            exit 1
          fi

          echo
          echo "=== HTTPS connectivity ==="
          if curl -sf --connect-timeout 10 --max-time 15 \
               -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" \
               "https://${BLOB_HOST}/" 2>&1; then
            echo "PASS: HTTPS connection succeeded"
          else
            echo "FAIL: cannot reach https://${BLOB_HOST}/"
            echo "Check Azure NSGs, firewall rules, or proxy settings."
            exit 1
          fi

          echo
          echo "Egress check complete."
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
EOF

log "Waiting for probe pod to complete (timeout ${TIMEOUT}s)"
elapsed=0
while (( elapsed < TIMEOUT )); do
  phase="$(oc get pod "${PROBE_NAME}" -n "${PROBE_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")"
  case "${phase}" in
    Succeeded)
      echo
      oc logs "${PROBE_NAME}" -n "${PROBE_NS}" 2>/dev/null
      echo
      log "Egress check passed"
      exit 0
      ;;
    Failed)
      echo
      oc logs "${PROBE_NAME}" -n "${PROBE_NS}" 2>/dev/null
      echo
      die "Egress check failed — see output above"
      ;;
    *)
      sleep 3
      elapsed=$((elapsed + 3))
      ;;
  esac
done

echo
log "Pod did not complete within ${TIMEOUT}s. Current status:"
oc get pod "${PROBE_NAME}" -n "${PROBE_NS}" -o wide 2>/dev/null || true
oc describe pod "${PROBE_NAME}" -n "${PROBE_NS}" 2>/dev/null | tail -15
die "Egress probe timed out. The pod may be stuck pulling the image or scheduling.
Try: oc get events -n ${PROBE_NS} --field-selector involvedObject.name=${PROBE_NAME}"
