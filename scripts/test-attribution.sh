#!/usr/bin/env bash
# Generate a mutating audit event and print the LogQL needed to verify
# that the acting user is attributed in Loki / the OpenShift console.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/test-attribution.sh [options]

Creates and deletes a temporary ConfigMap so kube-apiserver emits create
and delete audit events, then prints the LogQL query and console steps to
confirm the events landed in LokiStack with your username.

Options:
  -n, --namespace NAME   Namespace for the probe ConfigMap (default: default)
  --keep                 Do not delete the ConfigMap (you must delete it later)
  -h, --help             Show this help
EOF
}

PROBE_NS="${TEST_NAMESPACE:-default}"
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) PROBE_NS="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_oc

USER_NAME="$(oc whoami)"
STAMP="$(date -u +%Y%m%d%H%M%S)"
CM_NAME="audit-loki-probe-${STAMP}"

if ! oc get namespace "${PROBE_NS}" >/dev/null 2>&1; then
  die "Namespace ${PROBE_NS} does not exist"
fi

log "Creating ConfigMap ${CM_NAME} in ${PROBE_NS} as ${USER_NAME}"
oc create configmap "${CM_NAME}" \
  --namespace "${PROBE_NS}" \
  --from-literal=purpose=audit-attribution-probe \
  --from-literal=actor="${USER_NAME}" \
  --from-literal=issued-at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "${KEEP}" -eq 0 ]]; then
  log "Deleting ConfigMap ${CM_NAME}"
  oc delete configmap "${CM_NAME}" --namespace "${PROBE_NS}" --wait=true
else
  log "Leaving ConfigMap ${CM_NAME} in place (--keep)"
fi

# ViaQ stores the kube-apiserver event JSON in the message field.
QUERY="{log_type=\"audit\"} |= \`${CM_NAME}\` | json"
QUERY_DELETE="{log_type=\"audit\"} |= \`${CM_NAME}\` | json | verb=\"delete\""

cat <<EOF

Attribution probe issued.

  User:      ${USER_NAME}
  Namespace: ${PROBE_NS}
  ConfigMap: ${CM_NAME}
  Verbs:     create$([[ "${KEEP}" -eq 0 ]] && printf ', delete')

Wait 30–90 seconds for Vector to ship the events, then verify.

OpenShift console
  1. Observe -> Logs
  2. Select the Audit tenant (not Application / Infrastructure)
  3. Time range: Last 15 minutes
  4. Query:

     ${QUERY}

  5. Expand a hit and confirm:
       user.username  ==  ${USER_NAME}
       verb           ==  create  or  delete
       objectRef.name ==  ${CM_NAME}

Exact delete query:

  ${QUERY_DELETE}

CLI (optional, requires a Loki gateway route and a token that can query the audit tenant):

  oc -n ${NAMESPACE} exec -c grafana-proxy deploy/logging-loki-gateway -- \\
    wget -qO- --header "X-Scope-OrgID: audit" \\
    "http://localhost:8080/loki/api/v1/query_range?query=\$(printf %s '${QUERY}' | jq -sRr @uri)"

If nothing appears:
  * oc get clusterlogforwarder ${CLF_NAME} -n ${NAMESPACE}
  * oc logs -n ${NAMESPACE} -l app.kubernetes.io/component=collector --tail=50
  * Confirm the verb is not get/list/watch (those are dropped on purpose)
  * Confirm you are not a kube-system / openshift-* service account

See docs/logql-queries.md for more security queries.
EOF
