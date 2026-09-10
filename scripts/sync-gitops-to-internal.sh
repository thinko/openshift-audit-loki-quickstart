#!/usr/bin/env bash
# Sync gitops manifests to an internal repo directory, applying a
# cluster-specific overlay for values.yaml and clusters.yaml.
#
# Usage:
#   scripts/sync-gitops-to-internal.sh [--dry-run] <overlay-name> <target-dir>
#
# Flags:
#   --dry-run   Show what would change without modifying any files.
#
# Example:
#   scripts/sync-gitops-to-internal.sh --dry-run my-cluster \
#     ~/repos/internal-namespaces/namespaces/openshift-logging
#
# What it does:
#   1. Backs up every file that will be overwritten
#   2. Copies all generic manifests from gitops/namespaces/openshift-logging/
#   3. Overwrites values.yaml and clusters.yaml with the overlay versions
#   4. Copies the README.md
#   5. Shows a per-file diff summary and git diff --stat
#   6. Saves backup as ~/sync-backup-<overlay>-<timestamp>.tar.gz
#
# The tarball includes a rollback.sh script to restore overwritten files.
#
# The overlay directory must exist at _overlays/<name>/ and contain
# at least values.yaml and clusters.yaml with cluster-specific values.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Parse flags ──
DRY_RUN=false
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) shift; set -- ;; # fall through to usage
    *) echo "ERROR: Unknown flag: $1" >&2; exit 1 ;;
  esac
done

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] <overlay-name> <target-dir>

Arguments:
  overlay-name   Name of the overlay in _overlays/ (e.g. my-cluster)
  target-dir     Path to namespaces/openshift-logging/ in the internal repo

Flags:
  --dry-run      Show what would change without modifying any files

Example:
  $(basename "$0") --dry-run my-cluster ~/repos/internal/namespaces/openshift-logging
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage

OVERLAY_NAME="$1"
TARGET_DIR="$2"
OVERLAY_DIR="${ROOT}/_overlays/${OVERLAY_NAME}"
GITOPS_DIR="${ROOT}/gitops/namespaces/openshift-logging"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_TMPDIR="$(mktemp -d "/tmp/sync-backup-${OVERLAY_NAME}-${TIMESTAMP}-XXXXXX")"
BACKUP_TARBALL="${HOME}/sync-backup-${OVERLAY_NAME}-${TIMESTAMP}.tar.gz"

# ── Validate ──
if [[ ! -d "${OVERLAY_DIR}" ]]; then
  echo "ERROR: Overlay directory not found: ${OVERLAY_DIR}" >&2
  echo "Available overlays:" >&2
  ls -1 "${ROOT}/_overlays/" 2>/dev/null | grep -v '^_template$' | sed 's/^/  /' >&2 || echo "  (none)" >&2
  exit 1
fi

if [[ ! -d "${TARGET_DIR}" ]]; then
  echo "ERROR: Target directory not found: ${TARGET_DIR}" >&2
  echo "Create it first or check the path." >&2
  exit 1
fi

for required in values.yaml clusters.yaml; do
  if [[ ! -f "${OVERLAY_DIR}/${required}" ]]; then
    echo "ERROR: Overlay ${OVERLAY_NAME} is missing ${required}" >&2
    exit 1
  fi
done

# ── Helpers ──

# Classify a file as new/changed/unchanged and optionally show a diff.
# Sets FILE_STATUS for the caller.
FILE_STATUS=""
classify_file() {
  local src="$1" dst="$2" label="$3"
  local filename
  filename="$(basename "${dst}")"

  if [[ ! -f "${dst}" ]]; then
    FILE_STATUS="new"
    printf "    %-40s  %s\n" "${label}" "[NEW]"
  elif diff -q "${src}" "${dst}" >/dev/null 2>&1; then
    FILE_STATUS="unchanged"
    printf "    %-40s  %s\n" "${label}" "[unchanged]"
  else
    FILE_STATUS="changed"
    printf "    %-40s  %s\n" "${label}" "[CHANGED]"
    # diff returns 1 when files differ; suppress for pipefail
    local diff_output
    diff_output="$(diff -u "${dst}" "${src}" \
      --label "current/${filename}" --label "incoming/${filename}" \
      2>/dev/null || true)"
    local total
    total="$(echo "${diff_output}" | wc -l)"
    if [[ "${total}" -gt 40 ]]; then
      echo "${diff_output}" | head -40
      echo "    ... (${total} diff lines total, showing first 40)"
    else
      echo "${diff_output}"
    fi
    echo ""
  fi
}

# Back up a file before overwriting. No-op in dry-run mode.
backup_file() {
  local dst="$1"
  if [[ -f "${dst}" ]] && ! "${DRY_RUN}"; then
    cp "${dst}" "${BACKUP_TMPDIR}/$(basename "${dst}")"
  fi
}

# Copy src to dst, respecting dry-run mode.
sync_file() {
  local src="$1" dst="$2"
  if ! "${DRY_RUN}"; then
    cp "${src}" "${dst}"
  fi
}

# ── Header ──
if "${DRY_RUN}"; then
  echo "==> DRY RUN: showing what would change (no files modified)"
else
  echo "==> Syncing gitops manifests to: ${TARGET_DIR}"
fi
echo "    Overlay: ${OVERLAY_NAME}"
echo ""

CHANGED_COUNT=0
NEW_COUNT=0

# ── Step 1: Sync generic manifests ──
echo "  Generic manifests (gitops/namespaces/openshift-logging/):"
for yaml_file in "${GITOPS_DIR}"/*.yaml; do
  filename="$(basename "${yaml_file}")"
  dst="${TARGET_DIR}/${filename}"
  classify_file "${yaml_file}" "${dst}" "${filename}"
  case "${FILE_STATUS}" in
    changed) ((CHANGED_COUNT++)) || true; backup_file "${dst}"; sync_file "${yaml_file}" "${dst}" ;;
    new)     ((NEW_COUNT++)) || true; sync_file "${yaml_file}" "${dst}" ;;
    *)       sync_file "${yaml_file}" "${dst}" ;;
  esac
done

# ── Step 2: Sync README ──
if [[ -f "${GITOPS_DIR}/README.md" ]]; then
  dst="${TARGET_DIR}/README.md"
  classify_file "${GITOPS_DIR}/README.md" "${dst}" "README.md"
  case "${FILE_STATUS}" in
    changed) ((CHANGED_COUNT++)) || true; backup_file "${dst}"; sync_file "${GITOPS_DIR}/README.md" "${dst}" ;;
    new)     ((NEW_COUNT++)) || true; sync_file "${GITOPS_DIR}/README.md" "${dst}" ;;
    *)       sync_file "${GITOPS_DIR}/README.md" "${dst}" ;;
  esac
fi

# ── Step 3: Apply overlay (overwrites matching files) ──
echo ""
echo "  Overlay files (_overlays/${OVERLAY_NAME}/):"
for overlay_file in "${OVERLAY_DIR}"/*.yaml; do
  filename="$(basename "${overlay_file}")"
  dst="${TARGET_DIR}/${filename}"
  classify_file "${overlay_file}" "${dst}" "${filename} (overlay)"
  case "${FILE_STATUS}" in
    changed) ((CHANGED_COUNT++)) || true; backup_file "${dst}"; sync_file "${overlay_file}" "${dst}" ;;
    new)     ((NEW_COUNT++)) || true; sync_file "${overlay_file}" "${dst}" ;;
    *)       sync_file "${overlay_file}" "${dst}" ;;
  esac
done

# ── Summary ──
echo ""
echo "  Summary: ${CHANGED_COUNT} changed, ${NEW_COUNT} new"

if "${DRY_RUN}"; then
  echo ""
  echo "==> DRY RUN complete. No files were modified."
  echo "    Re-run without --dry-run to apply changes."
  exit 0
fi

# ── Step 4: Package backup tarball ──
# Check if any files were actually backed up (more than just the empty tmpdir)
BACKED_UP_COUNT="$(find "${BACKUP_TMPDIR}" -maxdepth 1 -type f | wc -l)"
if [[ "${BACKED_UP_COUNT}" -gt 0 ]]; then
  # Include a rollback script inside the tarball
  ROLLBACK_SCRIPT="${BACKUP_TMPDIR}/rollback.sh"
  {
    echo "#!/usr/bin/env bash"
    echo "# Rollback sync from ${TIMESTAMP} (overlay: ${OVERLAY_NAME})"
    echo "# Restores files that were overwritten during sync."
    echo "#"
    echo "# Usage:"
    echo "#   tar xzf ${BACKUP_TARBALL}"
    echo "#   cd $(basename "${BACKUP_TMPDIR}")"
    echo "#   ./rollback.sh <target-dir>"
    echo "#"
    echo "# Example:"
    echo "#   ./rollback.sh ${TARGET_DIR}"
    echo "set -euo pipefail"
    echo ""
    echo 'if [[ $# -lt 1 ]]; then'
    echo '  echo "Usage: $(basename "$0") <target-dir>" >&2'
    echo '  exit 1'
    echo 'fi'
    echo ""
    echo 'BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
    echo 'TARGET_DIR="$1"'
    echo ""
    for backed_up in "${BACKUP_TMPDIR}"/*; do
      [[ -f "${backed_up}" ]] || continue
      fname="$(basename "${backed_up}")"
      [[ "${fname}" == "rollback.sh" ]] && continue
      echo "echo \"  Restoring ${fname}\""
      echo "cp \"\${BACKUP_DIR}/${fname}\" \"\${TARGET_DIR}/${fname}\""
    done
    echo ""
    echo 'echo "Rollback complete. Review with: git -C ${TARGET_DIR} diff"'
  } > "${ROLLBACK_SCRIPT}"
  chmod +x "${ROLLBACK_SCRIPT}"

  # Create tarball in user's home directory
  tar czf "${BACKUP_TARBALL}" -C "$(dirname "${BACKUP_TMPDIR}")" "$(basename "${BACKUP_TMPDIR}")"

  echo ""
  echo "==> Backup tarball: ${BACKUP_TARBALL}"
  echo "    Contains ${BACKED_UP_COUNT} overwritten file(s) + rollback.sh"
  echo ""
  echo "    To undo this sync:"
  echo "      tar xzf ${BACKUP_TARBALL} -C /tmp"
  echo "      /tmp/$(basename "${BACKUP_TMPDIR}")/rollback.sh ${TARGET_DIR}"
fi

# Clean up temp directory
rm -rf "${BACKUP_TMPDIR}"

# ── Step 5: Show git diff if target is a git repo ──
if git -C "${TARGET_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  echo ""
  echo "==> Git diff in target repo:"
  git -C "${TARGET_DIR}" diff --stat || true
  echo ""
  echo "Review the changes, then:"
  echo "  cd $(cd "${TARGET_DIR}" && git rev-parse --show-toplevel)"
  echo "  git add namespaces/openshift-logging/"
  echo "  git commit -m 'chore: update openshift-logging manifests from upstream'"
  echo "  # Open a PR for peer review"
else
  echo ""
  echo "Target is not a git repo. Review the files manually before committing."
fi
