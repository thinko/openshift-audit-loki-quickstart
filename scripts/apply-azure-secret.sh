#!/usr/bin/env bash
# Create or update openshift-logging/logging-loki-azure from environment
# variables. Prefers Entra token mode when AZURE_CLIENT_ID is set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_oc
apply_azure_secret
