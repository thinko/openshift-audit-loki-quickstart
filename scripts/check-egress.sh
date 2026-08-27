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

# Resolve a trusted image from the cluster's own openshift/cli imagestream.
# Falls back to registry.redhat.io UBI if the imagestream isn't available.
resolve_probe_image() {
  if [[ -n "${PROBE_IMAGE:-}" ]]; then
    echo "${PROBE_IMAGE}"
    return
  fi
  local img
  img="$(oc get istag cli:latest -n openshift \
         -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)"
  if [[ -n "${img}" ]]; then
    echo "${img}"
  else
    echo "registry.redhat.io/ubi9/ubi-minimal:latest"
  fi
}

cleanup() {
  oc delete pod "${PROBE_NAME}" -n "${PROBE_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

IMAGE="$(resolve_probe_image)"
log "Testing egress from ${PROBE_NS} to ${BLOB_HOST}"
log "Probe image: ${IMAGE}"

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
      image: ${IMAGE}
      command:
        - bash
        - -c
        - |
          echo "=== DNS resolution ==="
          if command -v getent >/dev/null 2>&1; then
            if getent hosts ${BLOB_HOST} >/dev/null 2>&1; then
              resolved=\$(getent hosts ${BLOB_HOST} | head -1)
              echo "PASS: ${BLOB_HOST} resolves to \${resolved}"
            else
              echo "FAIL: cannot resolve ${BLOB_HOST}"
              exit 1
            fi
          elif command -v nslookup >/dev/null 2>&1; then
            if nslookup ${BLOB_HOST} >/dev/null 2>&1; then
              echo "PASS: ${BLOB_HOST} resolves (nslookup)"
            else
              echo "FAIL: cannot resolve ${BLOB_HOST}"
              exit 1
            fi
          else
            echo "SKIP: no DNS lookup tool available, testing connectivity directly"
          fi

          echo
          echo "=== HTTPS connectivity (port 443) ==="
          if command -v curl >/dev/null 2>&1; then
            http_code=\$(curl -sk --connect-timeout 10 --max-time 15 \
                 -o /dev/null -w "%{http_code}" \
                 "https://${BLOB_HOST}/" 2>/dev/null || echo "000")
            echo "HTTP \${http_code}"
            if [[ "\${http_code}" == "000" ]]; then
              echo "FAIL: cannot connect to https://${BLOB_HOST}/ (TCP/TLS failed)"
              echo "Check Azure NSGs, firewall rules, or proxy settings."
              exit 1
            elif [[ "\${http_code}" == "403" ]]; then
              echo "FAIL: storage account firewall is blocking this subnet (HTTP 403)"
              echo "Add the cluster VNet/subnet to the storage account firewall rules."
              exit 1
            else
              echo "PASS: HTTPS connection succeeded (HTTP \${http_code} is expected for unauthenticated Blob requests)"
            fi
          elif bash -c "echo >/dev/tcp/${BLOB_HOST}/443" 2>/dev/null; then
            echo "PASS: TCP 443 open to ${BLOB_HOST} (bash /dev/tcp)"
          else
            echo "FAIL: cannot connect to ${BLOB_HOST}:443"
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
