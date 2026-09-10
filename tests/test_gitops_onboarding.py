"""Structural checks for the GitOps namespace handoff folder."""

from pathlib import Path

import yaml

GITOPS_NS = Path("gitops") / "namespaces" / "openshift-logging"

REQUIRED_FILES = (
    "clusters.yaml",
    "values.yaml",
    "operatorgroup.yaml",
    "subscription.yaml",
    "lokistack.yaml",
    "collector-rbac.yaml",
    "clusterlogforwarder.yaml",
    "alerting.yaml",
    "grafana.yaml",
    "uiplugin.yaml",
    "loki-config-sp-overlay.yaml",
)


def _load_docs(path: Path) -> list[dict]:
    docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    assert docs, f"{path} produced no YAML documents"
    return docs


def test_gitops_required_files(repo_root: Path):
    folder = repo_root / GITOPS_NS
    missing = [name for name in REQUIRED_FILES if not (folder / name).is_file()]
    assert missing == [], f"missing GitOps files: {missing}"


def test_gitops_no_limitrange(repo_root: Path):
    """LimitRange was removed — ensure it does not come back."""
    folder = repo_root / GITOPS_NS
    assert not (folder / "limitrange.yaml").exists(), "limitrange.yaml should not exist in gitops"
    for path in folder.glob("*.yaml"):
        for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if doc:
                assert doc.get("kind") != "LimitRange", f"LimitRange found in {path.name}"


def test_gitops_cluster_placeholder(repo_root: Path):
    clusters = _load_docs(repo_root / GITOPS_NS / "clusters.yaml")[0]
    names = [c["name"] for c in clusters["clusters"]]
    assert names == ["REPLACE_ME_CLUSTER"]


def test_gitops_values_project_and_quota(repo_root: Path):
    values = yaml.safe_load((repo_root / GITOPS_NS / "values.yaml").read_text())
    assert values["project"]["name"] == "openshift-logging"
    assert values["project"]["annotations"]["openshift.io/node-selector"] == ""
    env = values["envs"][0]
    assert env["name"] == "REPLACE_ME_CLUSTER"
    assert env["spec_hard"]["requests"]["cpu"] >= 72
    mem = str(env["spec_hard"]["requests"]["memory"])
    assert mem.endswith("Gi")
    assert int(mem.removesuffix("Gi")) >= 176


def test_gitops_values_no_limits_section(repo_root: Path):
    """Quota must enforce requests only — no limits section."""
    values = yaml.safe_load((repo_root / GITOPS_NS / "values.yaml").read_text())
    env = values["envs"][0]
    assert "limits" not in env["spec_hard"], \
        "spec_hard should not have a 'limits' section; quota is requests-only"


def test_gitops_no_db2_node_pool(repo_root: Path):
    folder = repo_root / GITOPS_NS
    kinds = []
    for path in folder.glob("*.yaml"):
        text = path.read_text(encoding="utf-8")
        assert "type=db2" not in text, path.name
        for doc in yaml.safe_load_all(text):
            if doc:
                kinds.append(doc.get("kind"))
    assert "MachineConfigPool" not in kinds
    assert "KubeletConfig" not in kinds
    assert "CatalogSource" not in kinds
    assert "ImageContentSourcePolicy" not in kinds


def test_gitops_lokistack_test_profile(repo_root: Path):
    stack = next(
        d
        for d in _load_docs(repo_root / GITOPS_NS / "lokistack.yaml")
        if d["kind"] == "LokiStack"
    )
    spec = stack["spec"]
    assert spec["size"] in ("1x.extra-small", "1x.small", "1x.medium")
    assert spec["storage"]["secret"]["name"] == "logging-loki-azure"
    assert spec["storage"]["secret"]["type"] == "azure"
    assert spec["storage"]["secret"]["credentialMode"] == "static"
    assert spec["limits"]["tenants"]["audit"]["retention"]["days"] == 60
    assert spec["limits"]["tenants"]["infrastructure"]["retention"]["days"] == 60
    assert spec["limits"]["global"]["retention"]["days"] == 60


def test_gitops_no_azure_secret_manifest(repo_root: Path):
    folder = repo_root / GITOPS_NS
    for path in folder.glob("*.yaml"):
        for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if not doc:
                continue
            assert doc.get("kind") != "Secret", path.name


def test_gitops_operators_colocated(repo_root: Path):
    subs = {
        d["metadata"]["name"]: d
        for d in _load_docs(repo_root / GITOPS_NS / "subscription.yaml")
        if d["kind"] == "Subscription"
    }
    assert set(subs) == {"loki-operator", "cluster-logging"}
    for sub in subs.values():
        assert sub["metadata"]["namespace"] == "openshift-logging"
        assert sub["spec"]["channel"] == "stable-6.5"
        assert sub["spec"]["source"] == "redhat-operators"
    og = next(
        d
        for d in _load_docs(repo_root / GITOPS_NS / "operatorgroup.yaml")
        if d["kind"] == "OperatorGroup"
    )
    assert og["metadata"]["name"] == "openshift-logging"
    assert og["metadata"]["namespace"] == "openshift-logging"


def test_gitops_forwarder_and_alerts(repo_root: Path):
    clf = next(
        d
        for d in _load_docs(repo_root / GITOPS_NS / "clusterlogforwarder.yaml")
        if d["kind"] == "ClusterLogForwarder"
    )
    assert clf["apiVersion"] == "observability.openshift.io/v1"
    pipes = {p["name"] for p in clf["spec"]["pipelines"]}
    assert pipes == {"audit-to-loki", "infra-to-loki", "app-drop"}
    rule = next(
        d
        for d in _load_docs(repo_root / GITOPS_NS / "alerting.yaml")
        if d["kind"] == "PrometheusRule"
    )
    groups = {g["name"] for g in rule["spec"]["groups"]}
    assert groups == {"lokistack-health", "audit-pipeline-health"}
    kinds = {
        d["kind"]
        for d in _load_docs(repo_root / GITOPS_NS / "alerting.yaml")
    }
    assert "AlertmanagerConfig" not in kinds


def test_gitops_grafana_resources(repo_root: Path):
    """Grafana static resources must include Deployment, Service, Route, and RBAC."""
    docs = _load_docs(repo_root / GITOPS_NS / "grafana.yaml")
    kinds = {d["kind"] for d in docs}
    assert "Deployment" in kinds, "grafana.yaml missing Deployment"
    assert "Service" in kinds, "grafana.yaml missing Service"
    assert "Route" in kinds, "grafana.yaml missing Route"
    assert "ServiceAccount" in kinds, "grafana.yaml missing ServiceAccount"
    assert "ClusterRole" in kinds, "grafana.yaml missing ClusterRole"
    assert "ClusterRoleBinding" in kinds, "grafana.yaml missing ClusterRoleBinding"
    assert "ConfigMap" in kinds, "grafana.yaml missing ConfigMap"
    deployment = next(d for d in docs if d["kind"] == "Deployment")
    assert deployment["metadata"]["name"] == "loki-grafana"
    assert deployment["metadata"]["namespace"] == "openshift-logging"


def test_gitops_uiplugin(repo_root: Path):
    """UIPlugin CR must reference the LokiStack and have skip-dry-run annotation."""
    docs = _load_docs(repo_root / GITOPS_NS / "uiplugin.yaml")
    plugin = next(d for d in docs if d["kind"] == "UIPlugin")
    assert plugin["metadata"]["name"] == "logging"
    assert plugin["spec"]["type"] == "Logging"
    assert plugin["spec"]["logging"]["lokiStack"]["name"] == "logging-loki"
    annotations = plugin["metadata"].get("annotations", {})
    assert "SkipDryRunOnMissingResource=true" in annotations.get(
        "argocd.argoproj.io/sync-options", ""
    )


def test_gitops_sp_overlay_exists(repo_root: Path):
    """SP overlay must exist (even as placeholder)."""
    docs = _load_docs(repo_root / GITOPS_NS / "loki-config-sp-overlay.yaml")
    cm = next(d for d in docs if d["kind"] == "ConfigMap")
    assert cm["metadata"]["name"] == "logging-loki-config"
    assert cm["metadata"]["namespace"] == "openshift-logging"
