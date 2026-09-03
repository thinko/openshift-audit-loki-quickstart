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
    # Application logs are collected but dropped to silence the
    # ClusterLogForwarderRuntimeConfigurationMissingUnmatched alert.
    assert inputs["app-logs"]["type"] == "application"

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

    # Verify drop-all-app filter exists (catches all app logs).
    drop_all = filters["drop-all-app"]
    assert drop_all["type"] == "drop"
    assert drop_all["drop"][0]["test"][0]["field"] == ".message"
    assert drop_all["drop"][0]["test"][0]["matches"] == "."

    pipelines = {p["name"]: p for p in spec["pipelines"]}
    audit = pipelines["audit-to-loki"]
    assert audit["inputRefs"] == ["audit-logs"]
    assert audit["filterRefs"] == ["kube-api-audit-policy", "drop-audit-noise"]
    assert audit["outputRefs"] == ["local-loki"]

    # App-drop pipeline: collects application logs and drops them all.
    app_drop = pipelines["app-drop"]
    assert app_drop["inputRefs"] == ["app-logs"]
    assert app_drop["filterRefs"] == ["drop-all-app"]
    assert app_drop["outputRefs"] == ["local-loki"]


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
    # collect-application-logs is required for the app-drop pipeline
    # (silences the MissingUnmatched alert).
    assert "collect-application-logs" in roles


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


def test_alerting_prometheus_rules(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "12-alerting.yaml")
    rule = next(d for d in docs if d["kind"] == "PrometheusRule")
    assert rule["apiVersion"] == "monitoring.coreos.com/v1"
    assert rule["metadata"]["namespace"] == "openshift-logging"
    groups = {g["name"]: g for g in rule["spec"]["groups"]}
    assert "lokistack-health" in groups
    assert "audit-pipeline-health" in groups

    # LokiStack health group should have component readiness alerts.
    health_alerts = {r["alert"]: r for r in groups["lokistack-health"]["rules"]}
    assert "LokiIngesterNotReady" in health_alerts
    assert "LokiQuerierNotReady" in health_alerts
    assert "LokiCompactorNotReady" in health_alerts
    assert "LokiHighRequestErrorRate" in health_alerts
    assert "LokiPVCNearlyFull" in health_alerts
    assert "LokiComponentRestarting" in health_alerts
    # Critical alerts for ingester/querier.
    assert health_alerts["LokiIngesterNotReady"]["labels"]["severity"] == "critical"
    assert health_alerts["LokiQuerierNotReady"]["labels"]["severity"] == "critical"
    # Compactor is warning (less immediately impactful).
    assert health_alerts["LokiCompactorNotReady"]["labels"]["severity"] == "warning"

    # Audit pipeline group should have ingestion and filter alerts.
    pipeline_alerts = {r["alert"]: r for r in groups["audit-pipeline-health"]["rules"]}
    assert "AuditLogIngestionStopped" in pipeline_alerts
    assert "InfraLogIngestionStopped" in pipeline_alerts
    assert "AuditFilterEffectivenessLow" in pipeline_alerts
    assert "AuditIngestionSpike" in pipeline_alerts
    assert pipeline_alerts["AuditLogIngestionStopped"]["labels"]["severity"] == "critical"


def test_alerting_alertmanager_config(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "12-alerting.yaml")
    amc = next(d for d in docs if d["kind"] == "AlertmanagerConfig")
    assert amc["apiVersion"] == "monitoring.coreos.com/v1beta1"
    assert amc["metadata"]["namespace"] == "openshift-logging"
    assert amc["spec"]["route"]["receiver"] == "loki-audit-webhook"
    # Critical alerts get a shorter repeat interval.
    crit_route = amc["spec"]["route"]["routes"][0]
    assert crit_route["matchers"][0]["value"] == "critical"
    assert crit_route["repeatInterval"] == "1h"


def test_grafana_route_allows_slow_loki_panels(repo_root: Path):
    docs = _load_docs(repo_root / "manifests" / "08-grafana-instance.yaml")
    route = next(d for d in docs if d["kind"] == "Route")
    assert (
        route["metadata"]["annotations"]["haproxy.router.openshift.io/timeout"] == "5m"
    )
    cfg = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "grafana-config")
    assert "timeout = 60" in cfg["data"]["grafana.ini"]
    assert "keep_alive_seconds = 30" in cfg["data"]["grafana.ini"]
