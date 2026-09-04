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
)


def _load_docs(path: Path) -> list[dict]:
    docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    assert docs, f"{path} produced no YAML documents"
    return docs


def test_gitops_required_files(repo_root: Path):
    folder = repo_root / GITOPS_NS
    missing = [name for name in REQUIRED_FILES if not (folder / name).is_file()]
    assert missing == [], f"missing GitOps files: {missing}"


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
    assert env["spec_hard"]["requests"]["cpu"] >= 48
    mem = str(env["spec_hard"]["requests"]["memory"])
    assert mem.endswith("Gi")
    assert int(mem.removesuffix("Gi")) >= 96


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
    assert spec["size"] == "1x.small"
    assert spec["storage"]["secret"]["name"] == "logging-loki-azure"
    assert spec["storage"]["secret"]["type"] == "azure"
    assert spec["limits"]["tenants"]["audit"]["retention"]["days"] == 30
    assert spec["limits"]["tenants"]["infrastructure"]["retention"]["days"] == 14


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
