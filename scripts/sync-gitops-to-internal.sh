#!/usr/bin/env bash
# Sync gitops manifests to an internal repo directory, applying a
# cluster-specific overlay for values.yaml and clusters.yaml.
#
# Usage:
#   scripts/sync-gitops-to-internal.sh <overlay-name> <target-dir>
#
# Example:
#   scripts/sync-gitops-to-internal.sh d05 \
#     ~/repos/internal-namespaces/namespaces/openshift-logging
#
# What it does:
#   1. Copies all generic manifests from gitops/namespaces/openshift-logging/
#   2. Overwrites values.yaml and clusters.yaml with the overlay versions
#   3. Copies the README.md
#   4. Shows a git diff --stat if the target is a git repo
#
# The overlay directory must exist at _overlays/<name>/ and contain
# at least values.yaml and clusters.yaml with cluster-specific values.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") <overlay-name> <target-dir>

Arguments:
  overlay-name   Name of the overlay in _overlays/ (e.g. d05)
  target-dir     Path to namespaces/openshift-logging/ in the internal repo

Example:
  $(basename "$0") d05 ~/repos/internal/namespaces/openshift-logging
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage

OVERLAY_NAME="$1"
TARGET_DIR="$2"
OVERLAY_DIR="${ROOT}/_overlays/${OVERLAY_NAME}"
GITOPS_DIR="${ROOT}/gitops/namespaces/openshift-logging"

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

echo "==> Syncing gitops manifests to: ${TARGET_DIR}"
echo "    Overlay: ${OVERLAY_NAME}"
echo ""

# ── Step 1: Copy all generic manifests ──
echo "  Copying generic manifests..."
for yaml_file in "${GITOPS_DIR}"/*.yaml; do
  filename="$(basename "${yaml_file}")"
  cp "${yaml_file}" "${TARGET_DIR}/${filename}"
  echo "    ${filename}"
done

# ── Step 2: Copy README ──
if [[ -f "${GITOPS_DIR}/README.md" ]]; then
  cp "${GITOPS_DIR}/README.md" "${TARGET_DIR}/README.md"
  echo "    README.md"
fi

# ── Step 3: Apply overlay (overwrites values.yaml and clusters.yaml) ──
echo "  Applying overlay ${OVERLAY_NAME}..."
for overlay_file in "${OVERLAY_DIR}"/*.yaml; do
  filename="$(basename "${overlay_file}")"
  cp "${overlay_file}" "${TARGET_DIR}/${filename}"
  echo "    ${filename} (overlay)"
done

echo ""
echo "==> Sync complete."

# ── Step 4: Show diff if git repo ──
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
