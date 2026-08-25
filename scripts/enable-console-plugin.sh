#!/usr/bin/env bash
# Append logging-view-plugin to consoles.operator.openshift.io/cluster
# without replacing other plugins.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_oc
require_cluster_admin
enable_console_plugin
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}{"\n"}'
