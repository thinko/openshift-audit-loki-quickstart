#!/usr/bin/env bash
# Apply collector ServiceAccount and ClusterRoleBindings without creating the
# ClusterLogForwarder. Safe to run before LokiStack or Blob storage exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_oc
require_cluster_admin

log "Applying collector ServiceAccount and ClusterRoleBindings"

oc apply --server-side --field-manager=audit-loki-quickstart -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${COLLECTOR_SA}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: clusterlogforwarder
    app.kubernetes.io/component: collector
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-audit-logs
  labels:
    app.kubernetes.io/name: clusterlogforwarder
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-audit-logs
subjects:
  - kind: ServiceAccount
    name: ${COLLECTOR_SA}
    namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-logs-writer
  labels:
    app.kubernetes.io/name: clusterlogforwarder
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: logging-collector-logs-writer
subjects:
  - kind: ServiceAccount
    name: ${COLLECTOR_SA}
    namespace: ${NAMESPACE}
EOF

log "Collector RBAC applied. ClusterLogForwarder will be created by make deploy."
