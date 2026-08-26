#!/usr/bin/env bash
# Shared helpers for deploy / destroy / console-plugin scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

NAMESPACE="${NAMESPACE:-openshift-logging}"
LOKI_NAMESPACE="${LOKI_NAMESPACE:-openshift-logging}"
OPERATORS_NAMESPACE="${OPERATORS_NAMESPACE:-openshift-operators-redhat}"
LOKISTACK_NAME="${LOKISTACK_NAME:-logging-loki}"
CLF_NAME="${CLF_NAME:-audit}"
COLLECTOR_SA="${COLLECTOR_SA:-logging-collector}"
SECRET_NAME="${SECRET_NAME:-logging-loki-azure}"
CONSOLE_PLUGIN="${CONSOLE_PLUGIN:-logging-view-plugin}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

die() {
  err "$*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_oc() {
  need_cmd oc
  oc whoami >/dev/null 2>&1 || die "oc is not logged in. Run: oc login --server <api> --web"
}

require_cluster_admin() {
  local user
  user="$(oc whoami)"
  if ! oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
    die "Current user '${user}' is not cluster-admin. This install needs cluster-scoped RBAC and operator subscriptions."
  fi
  log "Authenticated as ${user} (cluster-admin check passed)"
}

wait_for_crd() {
  local crd="$1"
  local timeout="${2:-300}"
  log "Waiting for CRD ${crd} (timeout ${timeout}s)"
  local elapsed=0
  while (( elapsed < timeout )); do
    if oc get crd "${crd}" >/dev/null 2>&1; then
      log "CRD ${crd} is present"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "Timed out waiting for CRD ${crd}"
}

wait_for_csv() {
  local ns="$1"
  local timeout="${2:-600}"
  log "Waiting for a Succeeded ClusterServiceVersion in ${ns} (timeout ${timeout}s)"
  local elapsed=0
  while (( elapsed < timeout )); do
    if oc get csv -n "${ns}" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -qx Succeeded; then
      oc get csv -n "${ns}" --no-headers 2>/dev/null | awk '{print "  "$1, $NF}' || true
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  oc get csv -n "${ns}" || true
  die "Timed out waiting for operator CSV in ${ns}"
}

wait_for_lokistack() {
  local timeout="${1:-900}"
  log "Waiting for LokiStack/${LOKISTACK_NAME} Ready=True (timeout ${timeout}s)"
  if oc wait --for=condition=Ready "lokistack/${LOKISTACK_NAME}" \
      -n "${LOKI_NAMESPACE}" --timeout="${timeout}s" >/dev/null 2>&1; then
    log "LokiStack is Ready"
    return 0
  fi
  oc get lokistack "${LOKISTACK_NAME}" -n "${LOKI_NAMESPACE}" -o yaml | tail -n 80 || true
  die "LokiStack did not become Ready. Check Azure secret keys, storage class, and operator logs."
}

enable_console_plugin() {
  local plugins
  plugins="$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || true)"
  if [[ " ${plugins} " == *" ${CONSOLE_PLUGIN} "* ]]; then
    log "Console plugin ${CONSOLE_PLUGIN} is already enabled"
    return 0
  fi

  log "Enabling console plugin ${CONSOLE_PLUGIN} (preserving existing plugins)"
  if [[ -z "${plugins}" ]]; then
    oc patch consoles.operator.openshift.io cluster --type=merge \
      --patch "{\"spec\":{\"plugins\":[\"${CONSOLE_PLUGIN}\"]}}"
    return 0
  fi

  # Append without replacing the existing list.
  if oc patch consoles.operator.openshift.io cluster --type=json \
      --patch "[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${CONSOLE_PLUGIN}\"}]"; then
    return 0
  fi

  die "Failed to patch consoles.operator.openshift.io/cluster"
}

ensure_single_operatorgroup() {
  local ns="$1"
  local og_count
  og_count="$(oc get operatorgroup -n "${ns}" --no-headers 2>/dev/null | wc -l)"
  og_count="${og_count##* }"

  if (( og_count == 0 )); then
    log "No OperatorGroup in ${ns} — creating one"
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ns}
  namespace: ${ns}
spec:
  upgradeStrategy: Default
EOF
  elif (( og_count == 1 )); then
    local og_name
    og_name="$(oc get operatorgroup -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name)"
    log "OperatorGroup ${ns}/${og_name} already exists (count=1, OK)"
  else
    local og_names
    og_names="$(oc get operatorgroup -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)"
    die "Multiple OperatorGroups in ${ns} (count=${og_count}). OLM requires exactly one.
Found:
${og_names}

Fix: delete the extra OperatorGroup(s), then re-run. Example:
  oc delete operatorgroup <extra-name> -n ${ns}"
  fi
}

check_existing_clusterlogforwarders() {
  local ns="$1"
  local count
  count="$(oc get clusterlogforwarder.observability.openshift.io -n "${ns}" --no-headers 2>/dev/null | wc -l)"
  count="${count##* }"

  if (( count > 0 )); then
    local names
    names="$(oc get clusterlogforwarder.observability.openshift.io -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)"
    log "Existing ClusterLogForwarder(s) in ${ns}:"
    echo "${names}" | sed 's/^/  /'
    log "Our CLF (${CLF_NAME}) will run alongside them (separate collector DaemonSet per CLF)"
  fi
}

check_failed_csvs() {
  local ns="$1"
  local failed
  failed="$(oc get csv -n "${ns}" --no-headers 2>/dev/null | awk '$NF == "Failed" {print $1}')"
  if [[ -n "${failed}" ]]; then
    err "Failed CSVs in ${ns}:"
    echo "${failed}" | sed 's/^/  /' >&2
    err "Run: oc describe csv <name> -n ${ns}  to diagnose"
    return 1
  fi
  return 0
}

check_unapproved_installplans() {
  local ns="$1"
  local unapproved
  unapproved="$(oc get installplan -n "${ns}" --no-headers 2>/dev/null \
    | awk '$3 == "Manual" && $4 == "false" {print $1, $2}')"
  if [[ -n "${unapproved}" ]]; then
    err "Unapproved InstallPlans in ${ns}:"
    echo "${unapproved}" | sed 's/^/  /' >&2
    err "This can happen when multiple OperatorGroups exist. Fix OG count first."
    return 1
  fi
  return 0
}

azure_secret_has_required_keys() {
  oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 || return 1
  local key
  for key in account_name account_key container environment; do
    [[ -n "$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.data.${key}}" 2>/dev/null || true)" ]] || return 1
  done
  return 0
}

list_secret_key_names() {
  oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null || true
}

apply_azure_secret() {
  local account_name="${AZURE_STORAGE_ACCOUNT_NAME:-}"
  local account_key="${AZURE_STORAGE_ACCOUNT_KEY:-}"
  local container="${AZURE_CONTAINER_NAME:-${AZURE_STORAGE_CONTAINER:-loki-audit}}"
  local environment="${AZURE_ENVIRONMENT:-AzureGlobal}"

  if [[ -z "${account_name}" && -z "${account_key}" ]] && azure_secret_has_required_keys; then
    log "Reusing existing Secret ${NAMESPACE}/${SECRET_NAME} (keys are not printed)"
    return 0
  fi

  if [[ -z "${account_name}" || -z "${account_key}" ]]; then
    die "Azure Blob credentials are not available yet.

LokiStack cannot start without object storage. Either:
  * wait for the storage account, then set AZURE_STORAGE_ACCOUNT_NAME and AZURE_STORAGE_ACCOUNT_KEY
  * or have the cloud team create Secret ${NAMESPACE}/${SECRET_NAME} with keys
    account_name, account_key, container, environment
  * meanwhile: make deploy-operators

See docs/azure-blob-request.md for the storage request fields.
Optionally set AZURE_CONTAINER_NAME (default: loki-audit) and AZURE_ENVIRONMENT (default: AzureGlobal)."
  fi

  case "${environment}" in
    AzureGlobal|AzureChinaCloud|AzureGermanCloud|AzureUSGovernment) ;;
    *) die "AZURE_ENVIRONMENT must be AzureGlobal, AzureChinaCloud, AzureGermanCloud, or AzureUSGovernment" ;;
  esac

  log "Applying Azure Blob secret ${SECRET_NAME} in ${NAMESPACE} (key is not printed)"
  oc create secret generic "${SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    --from-literal=environment="${environment}" \
    --from-literal=account_name="${account_name}" \
    --from-literal=account_key="${account_key}" \
    --from-literal=container="${container}" \
    --dry-run=client -o yaml | oc apply -f -
}

assert_placeholders_absent() {
  local file="$1"
  if grep -E '<AZURE_STORAGE_ACCOUNT_(NAME|KEY)>|<CONTAINER_NAME>' "${file}" >/dev/null 2>&1; then
    die "File ${file} still contains placeholders. Fill credentials via environment variables instead of committing secrets."
  fi
}
