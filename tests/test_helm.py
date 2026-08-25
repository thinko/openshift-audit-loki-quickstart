"""Helm chart values and template sanity checks (helm binary optional)."""

import shutil
import subprocess
from pathlib import Path

import pytest
import yaml


def test_chart_metadata(repo_root: Path):
    chart = yaml.safe_load((repo_root / "helm" / "audit-loki" / "Chart.yaml").read_text())
    assert chart["name"] == "audit-loki"
    assert chart["version"] == "0.1.0"


def test_values_defaults(repo_root: Path):
    values = yaml.safe_load((repo_root / "helm" / "audit-loki" / "values.yaml").read_text())
    assert values["lokiStack"]["size"] == "1x.extra-small"
    assert values["lokiStack"]["storageClassName"] == "managed-csi"
    assert values["azure"]["existingSecret"] == ""
    assert values["azure"]["accountKey"] == ""
    drop = values["clusterLogForwarder"]["drop"]
    assert drop["verbPattern"] == "^(get|list|watch)$"
    assert "openshift-.*" in drop["usernamePattern"]


def test_secret_template_requires_credentials(repo_root: Path):
    template = (repo_root / "helm" / "audit-loki" / "templates" / "secret.yaml").read_text()
    assert "required" in template
    assert "azure.existingSecret" in template


@pytest.mark.skipif(shutil.which("helm") is None, reason="helm not installed")
def test_helm_template_renders_forwarder(repo_root: Path):
    chart = repo_root / "helm" / "audit-loki"
    result = subprocess.run(
        [
            "helm",
            "template",
            "audit-loki",
            str(chart),
            "--set",
            "azure.accountName=exampleaccount",
            "--set",
            "azure.accountKey=examplekey",
            "--set",
            "azure.container=loki-audit",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    kinds = {d["kind"] for d in docs}
    assert "LokiStack" in kinds
    assert "ClusterLogForwarder" in kinds
    assert "Subscription" in kinds
    clf = next(d for d in docs if d["kind"] == "ClusterLogForwarder")
    assert clf["apiVersion"] == "observability.openshift.io/v1"
    assert clf["spec"]["pipelines"][0]["inputRefs"] == ["audit-logs"]
