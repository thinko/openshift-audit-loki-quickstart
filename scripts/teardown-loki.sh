#!/usr/bin/env bash
# teardown-loki.sh — Remove all Loki deployment resources from openshift-logging.
#
# Purpose: Reset a cluster to a clean state so a fresh GitOps deployment can
#          be tested. Removes resources in dependency order (CRs → workloads →
#          operators) and avoids touching pre-existing platform resources.
#
# Usage:
#   ./scripts/teardown-loki.sh                  # interactive (confirms each group)
#   ./scripts/teardown-loki.sh --dry-run        # show what would be deleted
#   ./scripts/teardown-loki.sh --yes            # skip confirmations (careful!)
#   ./scripts/teardown-loki.sh --yes --dry-run  # list everything, no prompts
#
# Safety:
#   - Does NOT delete the openshift-logging namespace
#   - Does NOT delete the OperatorGroup (pre-existing, shared with Azure Monitor)
#   - Does NOT delete the ResourceQuota (platform-managed)
#   - Does NOT delete the LimitRange (platform-managed, if recreated)
#   - Asks for confirmation before each resource group unless --yes
#   - Dry-run mode shows oc commands without executing them
set -euo pipefail

NS="openshift-logging"
DRY_RUN=false
AUTO_YES=false
DELETED=0
SKIPPED=0
FAILED=0

# ── Parse flags ──────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  AUTO_YES=true ;;
    --help|-h)
      sed -n '2,21s/^# //p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      echo "Usage: $0 [--dry-run] [--yes]" >&2
      exit 1
      ;;
  esac
done

# ── Colours (disabled if not a terminal) ─────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ──────────────────────────────────────────────────────────
banner() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"; echo -e "${BOLD}  $1${RESET}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"; }
info()   { echo -e "${GREEN}  ✓${RESET} $1"; }
warn()   { echo -e "${YELLOW}  ⚠${RESET} $1"; }
err()    { echo -e "${RED}  ✗${RESET} $1"; }

confirm_group() {
  local group_name="$1"
  if $AUTO_YES; then return 0; fi
  echo ""
  read -rp "  Delete ${group_name}? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) warn "Skipped ${group_name}"; return 1 ;;
  esac
}

# Run or print an oc delete command. Tolerates "not found" gracefully.
run_delete() {
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} oc $*"
    return 0
  fi
  if oc "$@" 2>&1 | grep -qE '(deleted|"[^"]*" deleted)'; then
    DELETED=$((DELETED + 1))
    return 0
  fi
  # Re-run to capture actual output
  local output
  output=$(oc "$@" 2>&1) || true
  if echo "$output" | grep -qi "not found"; then
    info "Already gone: $(echo "$*" | tail -1)"
    SKIPPED=$((SKIPPED + 1))
  elif echo "$output" | grep -qi "deleted"; then
    DELETED=$((DELETED + 1))
  else
    err "Unexpected: $output"
    FAILED=$((FAILED + 1))
  fi
}

delete_if_exists() {
  local kind="$1" name="$2" ns_flag="${3:+"-n"}" ns_val="${3:-}"
  if $DRY_RUN; then
    if [[ -n "$ns_val" ]]; then
      echo -e "  ${YELLOW}[dry-run]${RESET} oc delete ${kind} ${name} -n ${ns_val} --ignore-not-found"
    else
      echo -e "  ${YELLOW}[dry-run]${RESET} oc delete ${kind} ${name} --ignore-not-found"
    fi
    return 0
  fi
  local output
  if [[ -n "$ns_val" ]]; then
    output=$(oc delete "$kind" "$name" -n "$ns_val" --ignore-not-found 2>&1) || true
  else
    output=$(oc delete "$kind" "$name" --ignore-not-found 2>&1) || true
  fi
  if echo "$output" | grep -qi "deleted"; then
    info "Deleted ${kind}/${name}"
    DELETED=$((DELETED + 1))
  elif [[ -z "$output" ]] || echo "$output" | grep -qi "not found"; then
    SKIPPED=$((SKIPPED + 1))
  else
    err "${kind}/${name}: $output"
    FAILED=$((FAILED + 1))
  fi
}

# ── Pre-flight checks ───────────────────────────────────────────────
banner "Loki Teardown — ${NS}"

if ! oc whoami &>/dev/null; then
  err "Not logged in. Run 'oc login' first."
  exit 1
fi

CURRENT_CTX=$(oc whoami --show-server 2>/dev/null || echo "unknown")
CURRENT_USER=$(oc whoami 2>/dev/null || echo "unknown")
echo -e "  Cluster:   ${BOLD}${CURRENT_CTX}${RESET}"
echo -e "  User:      ${BOLD}${CURRENT_USER}${RESET}"
echo -e "  Namespace: ${BOLD}${NS}${RESET}"
echo -e "  Dry-run:   ${BOLD}${DRY_RUN}${RESET}"
echo -e "  Auto-yes:  ${BOLD}${AUTO_YES}${RESET}"

if ! $AUTO_YES && ! $DRY_RUN; then
  echo ""
  echo -e "  ${RED}This will delete Loki, Grafana, operators, and all related${RESET}"
  echo -e "  ${RED}resources from ${NS}. PVCs with WAL data will be removed.${RESET}"
  echo ""
  read -rp "  Continue? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# ═══════════════════════════════════════════════════════════════════════
# Group 1: Custom Resources (must go before operators that manage them)
# ═══════════════════════════════════════════════════════════════════════
banner "Group 1: Custom Resources"
echo "  ClusterLogForwarder, LokiStack, UIPlugin"
echo "  These must be deleted before their operators to avoid finalizer hangs."

if confirm_group "Custom Resources"; then
  # ClusterLogForwarder first — removing it stops collector DaemonSet
  delete_if_exists clusterlogforwarder.observability.openshift.io loki-audit "$NS"

  # UIPlugin (may not exist if COO is not installed)
  delete_if_exists uiplugin.observability.openshift.io logging "$NS"

  # LokiStack — this cascades: StatefulSets, Services, ConfigMaps, etc.
  # Wait for it to finish (finalizers may take a moment)
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} oc delete lokistack logging-loki -n ${NS} --ignore-not-found --timeout=120s"
  else
    echo "  Deleting LokiStack (may take up to 2 minutes for finalizers)..."
    output=$(oc delete lokistack logging-loki -n "$NS" --ignore-not-found --timeout=120s 2>&1) || true
    if echo "$output" | grep -qi "deleted"; then
      info "Deleted LokiStack/logging-loki"
      DELETED=$((DELETED + 1))
    elif [[ -z "$output" ]]; then
      SKIPPED=$((SKIPPED + 1))
    else
      warn "LokiStack: $output"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Group 2: Grafana (Deployment, Service, Route, ConfigMaps, Secrets)
# ═══════════════════════════════════════════════════════════════════════
banner "Group 2: Grafana stack"
echo "  Deployment, Service, Route, ConfigMaps, Secrets, PostSync Job + RBAC"

if confirm_group "Grafana stack"; then
  # Workloads
  delete_if_exists deployment     loki-grafana "$NS"
  delete_if_exists service        loki-grafana "$NS"
  delete_if_exists route          loki-grafana "$NS"
  delete_if_exists job            grafana-postsync "$NS"

  # ConfigMaps
  delete_if_exists configmap grafana-config "$NS"
  delete_if_exists configmap grafana-datasource-provisioning "$NS"
  delete_if_exists configmap grafana-dashboard-provider "$NS"
  delete_if_exists configmap grafana-dashboards "$NS"

  # Secrets
  delete_if_exists secret grafana-admin-credentials "$NS"

  # Grafana RBAC (namespaced)
  delete_if_exists serviceaccount grafana-loki "$NS"
  delete_if_exists serviceaccount grafana-prometheus "$NS"
  delete_if_exists serviceaccount grafana-postsync "$NS"
  delete_if_exists role            grafana-postsync "$NS"
  delete_if_exists rolebinding     grafana-postsync "$NS"

  # Grafana RBAC (cluster-scoped)
  delete_if_exists clusterrole        grafana-loki-tenant-view
  delete_if_exists clusterrolebinding grafana-loki-tenant-view
  delete_if_exists clusterrolebinding grafana-prometheus-monitoring-view
fi

# ═══════════════════════════════════════════════════════════════════════
# Group 3: Alerting
# ═══════════════════════════════════════════════════════════════════════
banner "Group 3: Alerting rules"
echo "  PrometheusRule loki-audit-alerts"

if confirm_group "Alerting rules"; then
  delete_if_exists prometheusrule loki-audit-alerts "$NS"
fi

# ═══════════════════════════════════════════════════════════════════════
# Group 4: Collector RBAC
# ═══════════════════════════════════════════════════════════════════════
banner "Group 4: Collector RBAC"
echo "  ServiceAccount logging-collector + 4 ClusterRoleBindings"

if confirm_group "Collector RBAC"; then
  delete_if_exists serviceaccount     logging-collector "$NS"
  delete_if_exists clusterrolebinding logging-collector-audit-logs
  delete_if_exists clusterrolebinding logging-collector-logs-writer
  delete_if_exists clusterrolebinding logging-collector-infrastructure-logs
  delete_if_exists clusterrolebinding logging-collector-application-logs
fi

# ═══════════════════════════════════════════════════════════════════════
# Group 5: Secrets (storage)
# ═══════════════════════════════════════════════════════════════════════
banner "Group 5: Storage & config secrets"
echo "  logging-loki-azure (blob credentials)"
echo "  logging-loki-config (operator-generated, SP overlay)"

if confirm_group "Storage & config secrets"; then
  delete_if_exists secret logging-loki-azure "$NS"
  # Operator-generated ConfigMap (may have been patched with SP overlay)
  delete_if_exists configmap logging-loki-config "$NS"
fi

# ═══════════════════════════════════════════════════════════════════════
# Group 6: PVCs (Loki WAL/data)
# ═══════════════════════════════════════════════════════════════════════
banner "Group 6: Persistent Volume Claims"

if $DRY_RUN; then
  echo -e "  ${YELLOW}[dry-run]${RESET} oc get pvc -n ${NS} -l app.kubernetes.io/name=lokistack --no-headers"
  echo -e "  ${YELLOW}[dry-run]${RESET} (would delete all PVCs matching label app.kubernetes.io/name=lokistack)"
else
  PVC_LIST=$(oc get pvc -n "$NS" -l app.kubernetes.io/name=lokistack --no-headers 2>/dev/null || true)
  if [[ -z "$PVC_LIST" ]]; then
    # Fallback: match by naming convention
    PVC_LIST=$(oc get pvc -n "$NS" --no-headers 2>/dev/null | grep -E '(storage|wal).*loki' || true)
  fi

  if [[ -z "$PVC_LIST" ]]; then
    info "No Loki PVCs found"
  else
    echo "  Found PVCs:"
    echo "$PVC_LIST" | awk '{printf "    %-50s %s\n", $1, $4}'
    if confirm_group "Loki PVCs (WAL data will be lost)"; then
      echo "$PVC_LIST" | awk '{print $1}' | while read -r pvc; do
        delete_if_exists pvc "$pvc" "$NS"
      done
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Group 7: Operator Subscriptions & CSVs
# ═══════════════════════════════════════════════════════════════════════
banner "Group 7: Operator Subscriptions & CSVs"
echo "  loki-operator Subscription + CSV"
echo "  cluster-logging Subscription + CSV"
echo ""
echo -e "  ${YELLOW}Note: This removes the operators. OLM will NOT reinstall them${RESET}"
echo -e "  ${YELLOW}until ArgoCD re-syncs the Subscriptions.${RESET}"

if confirm_group "Operator Subscriptions & CSVs"; then
  # Delete Subscriptions first
  delete_if_exists subscription.operators.coreos.com loki-operator "$NS"
  delete_if_exists subscription.operators.coreos.com cluster-logging "$NS"

  # Find and delete CSVs (version in name varies)
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} oc get csv -n ${NS} --no-headers | grep -E 'loki|cluster-logging' | awk '{print \$1}'"
    echo -e "  ${YELLOW}[dry-run]${RESET} (would delete matching CSVs)"
  else
    CSV_LIST=$(oc get csv -n "$NS" --no-headers 2>/dev/null | grep -E 'loki|cluster-logging' | awk '{print $1}' || true)
    if [[ -z "$CSV_LIST" ]]; then
      info "No Loki/CLO CSVs found"
    else
      echo "$CSV_LIST" | while read -r csv; do
        delete_if_exists csv "$csv" "$NS"
      done
    fi
  fi

  # Clean up InstallPlans (optional, OLM garbage collects these)
  if ! $DRY_RUN; then
    IP_LIST=$(oc get installplan -n "$NS" --no-headers 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$IP_LIST" ]]; then
      echo "$IP_LIST" | while read -r ip; do
        delete_if_exists installplan "$ip" "$NS"
      done
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Group 8: Leftover operator-created resources
# ═══════════════════════════════════════════════════════════════════════
banner "Group 8: Operator-created leftovers"
echo "  Webhook configurations, operator ServiceAccounts, Deployments"
echo "  (Resources the operator/OLM may have created outside our manifests)"

if confirm_group "Operator-created leftovers"; then
  # ValidatingWebhookConfiguration (blocks LokiStack operations if orphaned)
  delete_if_exists validatingwebhookconfiguration loki-operator-controller-manager-validating-webhook

  # Operator deployment (OLM-managed, but removing CSV should handle it)
  delete_if_exists deployment loki-operator-controller-manager "$NS"

  # Operator service (webhook endpoint)
  delete_if_exists service loki-operator-controller-manager-service "$NS"

  # Operator metrics service
  delete_if_exists service loki-operator-controller-manager-metrics-service "$NS"

  # Operator service account
  delete_if_exists serviceaccount loki-operator-controller-manager "$NS"
fi

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
banner "Teardown complete"
if $DRY_RUN; then
  echo -e "  ${YELLOW}DRY RUN — no resources were modified${RESET}"
  echo ""
  echo "  Re-run without --dry-run to execute."
else
  echo -e "  Deleted:  ${GREEN}${DELETED}${RESET}"
  echo -e "  Skipped:  ${YELLOW}${SKIPPED}${RESET} (already absent)"
  echo -e "  Failed:   ${RED}${FAILED}${RESET}"
fi

echo ""
echo "  Resources NOT touched (platform-managed):"
echo "    • Namespace ${NS}"
echo "    • OperatorGroup (pre-existing, shared)"
echo "    • ResourceQuota (platform template)"
echo "    • LimitRange (if present)"
echo ""
echo "  To re-deploy via GitOps, push the manifests and let ArgoCD sync."
echo "  To re-deploy manually: make deploy"
