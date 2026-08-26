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


def test_namespace_manifest_omits_logging_operatorgroup(repo_root: Path):
    """The openshift-logging OperatorGroup must be created dynamically, not
    via static manifest, to avoid conflicts with pre-existing OGs."""
    text = (repo_root / "manifests" / "00-namespace.yaml").read_text(encoding="utf-8")
    assert "name: loki-operator" in text
    assert 'name: cluster-logging\n  namespace: openshift-logging' not in text
