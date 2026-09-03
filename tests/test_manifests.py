"""Structural checks for the raw OpenShift manifests."""

from pathlib import Path

import yaml


def _load_docs(path: Path) -> list[dict]:
    docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    assert docs, f"{path} produced no YAML documents"
    return docs


def test_namespace_manifest(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "00-namespace.yaml")
    kinds = {(d["kind"], d["metadata"]["name"]) for d in docs}
    assert ("Namespace", "openshift-logging") in kinds
    assert ("Namespace", "openshift-operators-redhat") in kinds
    assert ("OperatorGroup", "loki-operator") in kinds
    # openshift-logging OperatorGroup is created dynamically by deploy.sh
    # to avoid conflicts with pre-existing OperatorGroups on the cluster
    assert ("OperatorGroup", "cluster-logging") not in kinds


def test_operator_subscriptions(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "01-loki-operator-subscription.yaml")
    by_name = {d["metadata"]["name"]: d for d in docs}
    assert by_name["loki-operator"]["spec"]["channel"] == "stable-6.5"
    assert by_name["cluster-logging"]["spec"]["channel"] == "stable-6.5"
    assert by_name["loki-operator"]["spec"]["source"] == "redhat-operators"
    assert by_name["cluster-logging"]["spec"]["name"] == "cluster-logging"


def test_lokistack_sandbox_profile(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "03-lokistack.yaml")
    stack = next(d for d in docs if d["kind"] == "LokiStack")
    assert stack["apiVersion"] == "loki.grafana.com/v1"
    spec = stack["spec"]
    assert spec["size"] == "1x.extra-small"
    assert spec["storage"]["secret"]["type"] == "azure"
    assert spec["storage"]["secret"]["name"] == "logging-loki-azure"
    assert spec["storageClassName"] == "managed-csi"
    assert spec["tenants"]["mode"] == "openshift-logging"
    assert spec["storage"]["schemas"][0]["version"] == "v13"


def test_clusterlogforwarder_edge_filters(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "04-clusterlogforwarder.yaml")
    clf = next(d for d in docs if d["kind"] == "ClusterLogForwarder")
    assert clf["apiVersion"] == "observability.openshift.io/v1"
    spec = clf["spec"]
    assert spec["serviceAccount"]["name"] == "logging-collector"

    inputs = {i["name"]: i for i in spec["inputs"]}
    assert inputs["audit-logs"]["type"] == "audit"
    assert inputs["infra-logs"]["type"] == "infrastructure"
    assert inputs["infra-logs"]["infrastructure"]["sources"] == ["container", "node"]
    # Application logs are intentionally excluded from customer scope.
    assert "app-logs" not in inputs

    filters = {f["name"]: f for f in spec["filters"]}
    drop = filters["drop-audit-noise"]
    assert drop["type"] == "drop"
    tests = drop["drop"]
    # First entry drops watch, second drops get/list (except secrets),
    # third drops system account noise.
    assert tests[0]["test"][0]["field"] == ".verb"
    assert tests[0]["test"][0]["matches"] == "^watch$"
    assert tests[1]["test"][0]["matches"] == "^(get|list)$"
    assert tests[1]["test"][1]["field"] == ".objectRef.resource"
    assert tests[1]["test"][1]["notMatches"] == "^secrets$"
    user = tests[2]["test"][0]
    assert user["field"] == ".user.username"
    assert "serviceaccount:openshift-.*" in user["matches"]

    kube = filters["kube-api-audit-policy"]
    assert kube["type"] == "kubeAPIAudit"
    rules = kube["kubeAPIAudit"]["rules"]
    # System accounts dropped first, then secret reads kept, then blanket drop.
    assert rules[0]["level"] == "None"  # system account drop
    assert "system:node*" in rules[0]["users"]
    assert rules[1]["level"] == "Metadata"  # secret reads kept
    assert rules[1]["resources"][0]["resources"] == ["secrets"]
    assert rules[2]["level"] == "None"  # blanket get/list/watch drop
    assert rules[2]["verbs"] == ["get", "list", "watch"]

    outputs = {o["name"]: o for o in spec["outputs"]}
    loki = outputs["local-loki"]
    assert loki["type"] == "lokiStack"
    assert loki["lokiStack"]["target"]["name"] == "logging-loki"
    assert loki["tls"]["ca"]["configMapName"] == "openshift-service-ca.crt"

    pipeline = spec["pipelines"][0]
    assert pipeline["inputRefs"] == ["audit-logs"]
    assert pipeline["filterRefs"] == ["kube-api-audit-policy", "drop-audit-noise"]
    assert pipeline["outputRefs"] == ["local-loki"]


def test_no_legacy_logging_api(repo_root: Path):
    for path in (repo_root / "manifests").glob("*.yaml"):
        for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if not doc:
                continue
            api = str(doc.get("apiVersion", ""))
            assert api != "logging.openshift.io/v1", path


def test_collector_rbac_present(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "04-clusterlogforwarder.yaml")
    roles = [
        d["roleRef"]["name"]
        for d in docs
        if d["kind"] == "ClusterRoleBinding"
    ]
    assert "collect-audit-logs" in roles
    assert "logging-collector-logs-writer" in roles
    assert "collect-infrastructure-logs" in roles
    # collect-application-logs intentionally excluded from customer scope.


def test_grafana_loki_gateway_rbac(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "09-grafana-datasources.yaml")
    role = next(d for d in docs if d["kind"] == "ClusterRole")
    assert role["metadata"]["name"] == "grafana-loki-tenant-view"
    resources = set(role["rules"][0]["resources"])
    assert resources == {"application", "audit", "infrastructure"}
    assert role["rules"][0]["resourceNames"] == ["logs"]
    assert role["rules"][0]["verbs"] == ["get"]
    # Datasource provisioning is now a ConfigMap, not GrafanaDatasource CRDs.
    ds_cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "grafana-datasource-provisioning")
    ds_yaml = ds_cm["data"]["datasources.yaml"]
    assert "/api/logs/v1/audit" in ds_yaml
    assert "Authorization" in ds_yaml
    assert "timeout: 60" in ds_yaml
    assert "maxLines: 500" in ds_yaml


def test_grafana_route_allows_slow_loki_panels(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "08-grafana-instance.yaml")
    route = next(d for d in docs if d["kind"] == "Route")
    assert (
        route["metadata"]["annotations"]["haproxy.router.openshift.io/timeout"] == "5m"
    )
    cfg = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "grafana-config")
    assert "timeout = 60" in cfg["data"]["grafana.ini"]
    assert "keep_alive_seconds = 30" in cfg["data"]["grafana.ini"]
