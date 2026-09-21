#!/usr/bin/env bash
# Fill cluster environment variables from data this repo already has.
#
# Source it, then call load_cluster_env. Exports land in the current shell.
# The report lists every variable and the source that supplied it. Values
# stay hidden unless --show-values is given.
#
#   source scripts/load-cluster-env.sh
#   load_cluster_env --cluster arod08
#   load_cluster_env --cluster arod08 --show-values
#   load_cluster_env --cluster arod08 --set AZURE_ENVIRONMENT=AzureUSGovernment
#   load_cluster_env --cluster arod08 --skip AZURE_STORAGE_ACCOUNT_KEY
#
# Running the file prints `export` lines on stdout (for eval) and the same
# report on stderr.
#
# Precedence, first match wins:
#   1. --set / --skip
#   2. a variable that is already exported
#   3. Vault (${VAULT_BASE}/<cluster>/loki-storage)
#   4. --gitops-dir (the cluster copy of namespaces/openshift-logging)
#   5. _overlays/<cluster>/gitops-secrets-loki-storage.yaml
#   6. _overlays/<cluster>/values.yaml
#   7. gitops/namespaces/openshift-logging/values.yaml in this repo
#   8. _overlays/_customer/values-base.yaml
#   9. a derived default (container name, AzureGlobal, filler account key, ...)
#
# Cluster-specific edits usually live in the internal gitops checkout, not in
# _overlays/ on the machine that only has this repo. Point --gitops-dir at
# that namespaces/openshift-logging directory, or export GITOPS_LOGGING_DIR.
#
# Empty strings, TBD, and REPLACE_ME* placeholders are ignored.
# grafana_admin_password has no default: leave it unset and the Grafana
# PostSync hook generates one.
#
# VAULT_BASE is taken from the environment, or from the VAULT_BASE= line at
# the top of scripts/generate-overlay.sh when that line has been filled in.

_lce_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_lce_repo_root="$(cd "${_lce_script_dir}/.." && pwd)"

load_cluster_env() {
  local cluster="" show_values=0 vault_base="${VAULT_BASE:-}" root="${_lce_repo_root}"
  local gitops_dir="${GITOPS_LOGGING_DIR:-}"
  local tmp="" spec=""
  local -a specs=()
  _LCE_CLI_SET_NAMES=""
  _LCE_CLI_SKIP_NAMES=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster)
        [[ -n "${2:-}" && "${2}" != --* ]] || { printf 'ERROR: --cluster requires a name\n' >&2; return 1; }
        cluster="$2"
        shift 2
        ;;
      --cluster=*)
        cluster="${1#--cluster=}"
        [[ -n "${cluster}" ]] || { printf 'ERROR: --cluster requires a name\n' >&2; return 1; }
        shift
        ;;
      --show-values)
        show_values=1
        shift
        ;;
      --set)
        [[ -n "${2:-}" && "${2}" == *=* ]] || { printf 'ERROR: --set requires VAR=value\n' >&2; return 1; }
        _lce_cli_set "${2%%=*}" "${2#*=}" || return 1
        shift 2
        ;;
      --set=*)
        spec="${1#--set=}"
        [[ "${spec}" == *=* ]] || { printf 'ERROR: --set requires VAR=value\n' >&2; return 1; }
        _lce_cli_set "${spec%%=*}" "${spec#*=}" || return 1
        shift
        ;;
      --skip)
        [[ -n "${2:-}" && "${2}" != --* ]] || { printf 'ERROR: --skip requires a variable name\n' >&2; return 1; }
        _lce_cli_skip "$2" || return 1
        shift 2
        ;;
      --vault-base)
        [[ -n "${2:-}" && "${2}" != --* ]] || { printf 'ERROR: --vault-base requires a path\n' >&2; return 1; }
        vault_base="$2"
        shift 2
        ;;
      --root)
        [[ -n "${2:-}" && "${2}" != --* ]] || { printf 'ERROR: --root requires a directory\n' >&2; return 1; }
        root="$2"
        shift 2
        ;;
      --gitops-dir)
        [[ -n "${2:-}" && "${2}" != --* ]] || { printf 'ERROR: --gitops-dir requires a directory\n' >&2; return 1; }
        gitops_dir="$2"
        shift 2
        ;;
      -h|--help)
        _lce_usage
        return 0
        ;;
      *)
        printf 'ERROR: unknown argument: %s\n' "$1" >&2
        _lce_usage >&2
        return 1
        ;;
    esac
  done

  [[ -n "${cluster}" ]] || { printf 'ERROR: --cluster is required\n' >&2; _lce_usage >&2; return 1; }
  cluster="$(printf '%s' "${cluster}" | tr '[:upper:]' '[:lower:]')"

  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/vault" "${tmp}/resolved" "${tmp}/source" "${tmp}/skipped"

  if [[ -z "${vault_base}" ]]; then
    vault_base="$(_lce_vault_base_from_script "${root}")"
  fi
  vault_base="${vault_base%/}"

  _lce_apply_cli "${tmp}"
  _lce_load_vault "${tmp}" "${vault_base}" "${cluster}"
  _lce_prepare_secrets_file "${tmp}" "${root}" "${cluster}"
  if [[ -n "${gitops_dir}" ]]; then
    [[ -d "${gitops_dir}" ]] || { printf 'ERROR: --gitops-dir is not a directory: %s\n' "${gitops_dir}" >&2; rm -rf "${tmp}"; return 1; }
    _lce_dedent_secrets "${gitops_dir}/gitops-secrets-loki-storage.yaml" "${tmp}/gitops-secrets.yaml"
  fi

  _lce_offer "${tmp}" CLUSTER "${cluster}" argument
  _lce_offer "${tmp}" ARO_CLUSTER_NAME "${cluster}" argument

  specs=(
    "AZURE_STORAGE_ACCOUNT_NAME|account_name|none|.secrets.loki_storage.account_name|"
    "AZURE_STORAGE_ACCOUNT_KEY|account_key|account_key|.secrets.loki_storage.account_key|"
    "AZURE_CONTAINER_NAME|container|container|.secrets.loki_storage.container|"
    "AZURE_ENVIRONMENT|environment|environment|.secrets.loki_storage.environment|"
    "AZURE_SP_CLIENT_ID|client_id|none|.secrets.loki_storage.client_id|"
    "AZURE_SP_CLIENT_SECRET|client_secret|none|.secrets.loki_storage.client_secret|"
    "AZURE_SP_TENANT_ID|tenant_id|tenant|.secrets.loki_storage.tenant_id|"
    "GRAFANA_IMAGE|grafana_image|none|.secrets.loki_storage.grafana_image|.grafana_image"
    "GRAFANA_ADMIN_PASSWORD|grafana_admin_password|none|.secrets.loki_storage.grafana_admin_password|"
    "DEPLOYMENT_ID|deployment_id|deployment_id|.envs[0].deployment_id|"
    "RBAC_EDIT|rbac_edit|none|.envs[0].rbac.edit|.rbac.edit"
    "RBAC_VIEW|rbac_view|none|.envs[0].rbac.view|.rbac.view"
    "LOKISTACK_SIZE|lokistack_size|size|.secrets.loki_storage.lokistack_size|"
    "LOKI_MANAGEMENT_STATE|management_state|managed|.secrets.loki_storage.management_state|"
    "STORAGE_CLASS|storage_class|storage_class|.secrets.loki_storage.storage_class|"
  )

  local env_name vault_key default_kind values_expr customer_expr
  local from_vault from_secrets from_customer from_default
  for spec in "${specs[@]}"; do
    IFS='|' read -r env_name vault_key default_kind values_expr customer_expr <<<"${spec}"
    _lce_offer_env "${tmp}" "${env_name}"
    from_vault="$(_lce_file_value "${tmp}/vault/${vault_key}")"
    _lce_offer "${tmp}" "${env_name}" "${from_vault}" vault
    if [[ -n "${gitops_dir}" ]]; then
      from_secrets="$(_lce_yaml "${tmp}/gitops-secrets.yaml" ".loki_storage.${vault_key}")"
      _lce_offer "${tmp}" "${env_name}" "${from_secrets}" "gitops secrets"
      _lce_offer_values_file "${tmp}" "${env_name}" "${gitops_dir}/values.yaml" "${values_expr}" "${vault_key}" "gitops values"
    fi
    from_secrets="$(_lce_yaml "${tmp}/secrets.yaml" ".loki_storage.${vault_key}")"
    _lce_offer "${tmp}" "${env_name}" "${from_secrets}" "overlay secrets"
    _lce_offer_values_file "${tmp}" "${env_name}" "${root}/_overlays/${cluster}/values.yaml" "${values_expr}" "${vault_key}" "overlay values"
    _lce_offer_values_file "${tmp}" "${env_name}" "${root}/gitops/namespaces/openshift-logging/values.yaml" "${values_expr}" "${vault_key}" "repo gitops values"
    if [[ -n "${customer_expr}" ]]; then
      from_customer="$(_lce_yaml "${root}/_overlays/_customer/values-base.yaml" "${customer_expr}")"
      _lce_offer "${tmp}" "${env_name}" "${from_customer}" "customer base"
    fi
    from_default="$(_lce_default "${default_kind}" "${cluster}")"
    _lce_offer "${tmp}" "${env_name}" "${from_default}" default
  done

  if [[ "${show_values}" -eq 1 ]]; then
    printf '%-28s %-16s %s\n' "VARIABLE" "SOURCE" "VALUE" >&2
  else
    printf '%-28s %s\n' "VARIABLE" "SOURCE" >&2
  fi
  _lce_emit "${tmp}" CLUSTER "${show_values}"
  _lce_emit "${tmp}" ARO_CLUSTER_NAME "${show_values}"
  for spec in "${specs[@]}"; do
    IFS='|' read -r env_name _ <<<"${spec}"
    _lce_emit "${tmp}" "${env_name}" "${show_values}"
  done
  rm -rf "${tmp}"
}

_lce_usage() {
  cat <<'EOF'
usage: load_cluster_env --cluster NAME [options]

  --show-values          print the value next to each variable that was set
  --set VAR=value        set VAR and ignore vault, overlays, and defaults
  --skip VAR             leave VAR unset
  --vault-base PATH      Vault prefix (default: VAULT_BASE, or generate-overlay.sh)
  --gitops-dir DIR       cluster copy of namespaces/openshift-logging
                         (default: GITOPS_LOGGING_DIR)
  --root DIR             repository root (default: this repo)

source scripts/load-cluster-env.sh
load_cluster_env --cluster arod08
EOF
}

_lce_usable() {
  [[ -n "${1:-}" && "${1}" != "TBD" && "${1}" != "null" && "${1}" != '""' ]] || return 1
  [[ "${1}" == REPLACE_ME* ]] && return 1
  return 0
}

_lce_offer_values_file() {
  local tmp="$1" name="$2" file="$3" expr="$4" vault_key="$5" source="$6" value
  value="$(_lce_yaml "${file}" "${expr}")"
  if ! _lce_usable "${value}"; then
    value="$(_lce_yaml "${file}" ".secrets.loki_storage.${vault_key}")"
  fi
  _lce_offer "${tmp}" "${name}" "${value}" "${source}"
}

_lce_file_value() {
  [[ -f "$1" ]] || return 0
  cat "$1"
}

_lce_vault_base_from_script() {
  local root="$1" line raw
  local file="${root}/scripts/generate-overlay.sh"
  [[ -f "${file}" ]] || return 0
  line="$(grep -E '^VAULT_BASE=' "${file}" | head -n 1 || true)"
  raw="${line#VAULT_BASE=}"
  raw="${raw%\"}"
  raw="${raw#\"}"
  raw="${raw%\'}"
  raw="${raw#\'}"
  if [[ "${raw}" == *'${VAULT_BASE:-'* ]]; then
    raw="${raw#*\$\{VAULT_BASE:-}"
    raw="${raw%%\}*}"
  fi
  [[ "${raw}" == *'$'* ]] && raw=""
  printf '%s' "${raw}"
}

_lce_list_drop() {
  local which="$1" name="$2" current
  eval "current=\${${which}-}"
  current=" ${current} "
  current="${current// ${name} / }"
  # shellcheck disable=SC2086
  eval "${which}=\"${current}\""
}

_lce_cli_set() {
  local name="$1" value="$2"
  [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'ERROR: invalid variable name: %s\n' "${name}" >&2; return 1; }
  _lce_list_drop _LCE_CLI_SKIP_NAMES "${name}"
  _lce_list_drop _LCE_CLI_SET_NAMES "${name}"
  _LCE_CLI_SET_NAMES="${_LCE_CLI_SET_NAMES:-} ${name}"
  printf -v "_LCE_CLI_VAL_${name}" '%s' "${value}"
}

_lce_cli_skip() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'ERROR: invalid variable name: %s\n' "${name}" >&2; return 1; }
  _lce_list_drop _LCE_CLI_SET_NAMES "${name}"
  _lce_list_drop _LCE_CLI_SKIP_NAMES "${name}"
  _LCE_CLI_SKIP_NAMES="${_LCE_CLI_SKIP_NAMES:-} ${name}"
  unset "_LCE_CLI_VAL_${name}"
}

_lce_apply_cli() {
  local tmp="$1" name
  for name in ${_LCE_CLI_SKIP_NAMES:-}; do
    : > "${tmp}/skipped/${name}"
  done
  for name in ${_LCE_CLI_SET_NAMES:-}; do
    [[ -f "${tmp}/skipped/${name}" ]] && continue
    eval "printf '%s' \"\${_LCE_CLI_VAL_${name}}\"" > "${tmp}/resolved/${name}"
    printf '%s' "command line" > "${tmp}/source/${name}"
  done
}

_lce_load_vault() {
  local tmp="$1" vault_base="$2" cluster="$3" path line key value
  [[ -n "${vault_base}" ]] || { printf 'vault: VAULT_BASE is unset; vault was not consulted\n' >&2; return 0; }
  command -v safe >/dev/null 2>&1 || { printf 'vault: safe is not installed; vault was not consulted\n' >&2; return 0; }
  path="${vault_base}/${cluster}/loki-storage"
  if ! safe get "${path}" >"${tmp}/vault.out" 2>"${tmp}/vault.err"; then
    printf 'vault: safe get failed for %s\n' "${path}" >&2
    return 0
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      ""|---*) continue ;;
    esac
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value#"${value%%[![:space:]]*}"}"
      printf '%s' "${value}" > "${tmp}/vault/${key}"
    fi
  done < "${tmp}/vault.out"
}

_lce_dedent_secrets() {
  local src="$1" dest="$2"
  [[ -f "${src}" ]] || return 0
  sed 's/^  //' "${src}" > "${dest}"
}

_lce_prepare_secrets_file() {
  local tmp="$1" root="$2" cluster="$3"
  _lce_dedent_secrets "${root}/_overlays/${cluster}/gitops-secrets-loki-storage.yaml" "${tmp}/secrets.yaml"
}

_lce_yaml() {
  local file="$1" expr="$2" kind value
  [[ -n "${expr}" && -f "${file}" ]] || return 0
  kind="$(yq -r "${expr} | type" "${file}" 2>/dev/null || true)"
  case "${kind}" in
    '!!seq')
      value="$(yq -r "${expr} | map(select(. != \"\" and . != \"TBD\")) | join(\",\")" "${file}" 2>/dev/null || true)"
      ;;
    '!!str')
      value="$(yq -r "${expr}" "${file}" 2>/dev/null || true)"
      ;;
    *)
      value=""
      ;;
  esac
  [[ "${value}" == "TBD" || "${value}" == "null" ]] && value=""
  printf '%s' "${value}"
}

_lce_offer_env() {
  local tmp="$1" name="$2" current=""
  [[ -f "${tmp}/skipped/${name}" || -f "${tmp}/resolved/${name}" ]] && return 0
  eval "current=\${${name}-}"
  _lce_offer "${tmp}" "${name}" "${current}" environment
}

_lce_offer() {
  local tmp="$1" name="$2" value="$3" source="$4"
  [[ -f "${tmp}/skipped/${name}" || -f "${tmp}/resolved/${name}" ]] && return 0
  _lce_usable "${value}" || return 0
  printf '%s' "${value}" > "${tmp}/resolved/${name}"
  printf '%s' "${source}" > "${tmp}/source/${name}"
}

_lce_default() {
  local kind="$1" cluster="$2"
  case "${kind}" in
    container) printf '%s' "${cluster}-audit-loki" ;;
    environment) printf '%s' "AzureGlobal" ;;
    account_key) printf 'unused' | base64 | tr -d '\n' | base64 | tr -d '\n' ;;
    deployment_id) printf '%s' "${cluster}-logging" ;;
    size) printf '%s' "1x.small" ;;
    managed) printf '%s' "Managed" ;;
    storage_class) printf '%s' "managed-csi" ;;
    tenant)
      command -v az >/dev/null 2>&1 || return 0
      az account show --query tenantId -o tsv 2>/dev/null || true
      ;;
    none) ;;
  esac
}

_lce_emit() {
  local tmp="$1" name="$2" show_values="$3" value="" source="unset" sourced=0
  if [[ -f "${tmp}/skipped/${name}" ]]; then
    source="skipped"
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
      printf 'unset %s\n' "${name}"
    else
      unset "${name}"
    fi
  elif [[ -f "${tmp}/resolved/${name}" ]]; then
    value="$(cat "${tmp}/resolved/${name}")"
    source="$(cat "${tmp}/source/${name}")"
    sourced=1
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
      printf 'export %s=%q\n' "${name}" "${value}"
    else
      printf -v "${name}" '%s' "${value}"
      export "${name}"
    fi
  fi
  if [[ "${show_values}" -eq 1 && "${sourced}" -eq 1 ]]; then
    printf '%-28s %-16s %s\n' "${name}" "${source}" "${value}" >&2
  else
    printf '%-28s %s\n' "${name}" "${source}" >&2
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  load_cluster_env "$@"
fi
