"""Shell scripts must be executable-safe and parse under bash -n."""

import subprocess
from pathlib import Path


def test_scripts_bash_n(repo_root: Path):
    scripts = sorted((repo_root / "scripts").glob("*.sh"))
    assert scripts, "expected scripts in scripts/"
    for script in scripts:
        subprocess.run(["bash", "-n", str(script)], check=True)


def test_scripts_use_strict_mode(repo_root: Path):
    for script in (repo_root / "scripts").glob("*.sh"):
        text = script.read_text(encoding="utf-8")
        assert "set -euo pipefail" in text, script.name


def test_create_azure_storage_is_anonymized_and_defers_ocp_secret(repo_root: Path):
    text = (repo_root / "scripts" / "create-azure-storage.sh").read_text(encoding="utf-8")
    assert "AZURE_RESOURCE_GROUP" in text
    assert "logging-loki-azure" in text
    assert "oc create secret" not in text
    assert "--enable-hierarchical-namespace false" in text
    assert "create-azure-container.sh" in text
    assert "--container-only" in text


def test_create_azure_container_does_not_create_an_account(repo_root: Path):
    text = (repo_root / "scripts" / "create-azure-container.sh").read_text(encoding="utf-8")
    assert "az storage account create" not in text
    assert "az storage container create" in text
    assert "--auth-mode login" in text
    assert "one container per cluster" in text
    assert "-audit-loki" in text
    assert "--cluster" in text
    assert "az storage account list" in text
    assert "oc create secret" not in text


def test_add_storage_subnet_discovers_from_cluster_name(repo_root: Path):
    text = (repo_root / "scripts" / "add-storage-subnet.sh").read_text(encoding="utf-8")
    assert "require_az_login" in text
    assert "az aro list" in text
    assert "az storage account list" in text
    assert "Pass --cluster" in text
    common = (repo_root / "scripts" / "common.sh").read_text(encoding="utf-8")
    assert "az account show" in common


def test_generate_overlay_leaves_grafana_password_to_postsync(repo_root: Path):
    text = (repo_root / "scripts" / "generate-overlay.sh").read_text(encoding="utf-8")
    assert "grafana_admin_password=<PASSWORD>" not in text
    assert "PostSync hook will generate one" in text
    assert "1x.medium" in text
    assert "tenantId" in text
    assert "customer_shared '.grafana_image'" in text
    assert "customer_shared '.rbac.edit'" in text
    assert "--from <sibling-cluster>" in text
    assert "declare -A" not in text
    assert "local -n" not in text
    assert '${CLUSTER^^}' not in text
    assert "CLUSTER_UC=" in text
    assert "printf 'unused' | base64 | tr -d '\\n' | base64 | tr -d '\\n'" in text
    assert "NEED_SAFE_SET=1" in text
    assert "Create it from the sibling values" in text
    assert "kv_get" in text
    assert 'VAULT_BASE="${VAULT_BASE:-}"' in text
    assert "Set VAULT_BASE" in text
    assert '""|---*)' in text
    sibling_keys = text.split("SIBLING_KEYS=(", 1)[1].split(")", 1)[0]
    for key in ("grafana_image", "rbac_edit", "rbac_view", "client_id", "account_name"):
        assert key in sibling_keys
    for key in ("container", "deployment_id", "grafana_admin_password", "management_state"):
        assert key not in sibling_keys
    base = (repo_root / "_overlays" / "_customer" / "values-base.yaml").read_text(encoding="utf-8")
    assert "grafana_image:" in base
    assert "edit:" in base
    assert "view:" in base


def test_deploy_supports_operators_only(repo_root: Path):
    text = (repo_root / "scripts" / "deploy.sh").read_text(encoding="utf-8")
    assert "--operators-only" in text
    assert "make deploy-operators" in (repo_root / "Makefile").read_text(encoding="utf-8")


def test_deploy_checks_operatorgroups_before_subscriptions(repo_root: Path):
    text = (repo_root / "scripts" / "deploy.sh").read_text(encoding="utf-8")
    og_pos = text.index("ensure_single_operatorgroup")
    sub_pos = text.index("01-loki-operator-subscription.yaml")
    assert og_pos < sub_pos, "OperatorGroup check must run before applying subscriptions"


def test_common_has_operatorgroup_helpers(repo_root: Path):
    text = (repo_root / "scripts" / "common.sh").read_text(encoding="utf-8")
    assert "ensure_single_operatorgroup" in text
    assert "check_failed_csvs" in text
    assert "check_unapproved_installplans" in text
    assert "azure_secret_has_token_keys" in text
    assert "client_id" in text


def test_namespace_manifest_omits_logging_operatorgroup(repo_root: Path):
    """The openshift-logging OperatorGroup must be created dynamically, not
    via static manifest, to avoid conflicts with pre-existing OGs."""
    text = (repo_root / "manifests" / "00-namespace.yaml").read_text(encoding="utf-8")
    assert "name: loki-operator" in text
    assert 'name: cluster-logging\n  namespace: openshift-logging' not in text
