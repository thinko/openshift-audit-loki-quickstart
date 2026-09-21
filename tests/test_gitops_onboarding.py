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
    "grafana-postsync.yaml",
    "grafana-dashboards.yaml",
    "uiplugin.yaml",
    "loki-config-sp-overlay.yaml",
    "storage-secret.yaml",
    "grafana-secret.yaml",
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


def test_gitops_values_limits_memory_set(repo_root: Path):
    """spec_hard.limits.memory must be set to override platform 20Gi default."""
    values = yaml.safe_load((repo_root / GITOPS_NS / "values.yaml").read_text())
    env = values["envs"][0]
    limits = env["spec_hard"].get("limits", {})
    assert "memory" in limits, \
        "spec_hard.limits.memory must be set; platform defaults to 20Gi otherwise"
    mem = str(limits["memory"])
    assert mem.endswith("Gi")
    assert int(mem.removesuffix("Gi")) >= 128, \
        "limits.memory should be >= 128Gi (at least 1.5× requests.memory)"


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
    # size, managementState, storageClassName are now ytt expressions;
    # yaml.safe_load parses them as None. Validate via raw text instead.
    content = (repo_root / GITOPS_NS / "lokistack.yaml").read_text()
    assert "1x.small" in content, "lokistack.yaml must reference 1x.small as default size"
    assert spec["storage"]["secret"]["name"] == "logging-loki-azure"
    assert spec["storage"]["secret"]["type"] == "azure"
    assert spec["storage"]["secret"]["credentialMode"] == "static"
    assert spec["limits"]["tenants"]["audit"]["retention"]["days"] == 60
    assert spec["limits"]["tenants"]["infrastructure"]["retention"]["days"] == 60
    assert spec["limits"]["global"]["retention"]["days"] == 60


def test_gitops_no_azure_secret_manifest(repo_root: Path):
    """No hardcoded secrets. ytt-templated *-secret.yaml files are allowed."""
    ytt_secret_templates = {"storage-secret.yaml", "grafana-secret.yaml"}
    folder = repo_root / GITOPS_NS
    for path in folder.glob("*.yaml"):
        if path.name in ytt_secret_templates:
            continue
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


def test_gitops_grafana_postsync_hook(repo_root: Path):
    """PostSync hook must have correct ArgoCD annotations and create tokens."""
    docs = _load_docs(repo_root / GITOPS_NS / "grafana-postsync.yaml")
    kinds = {d["kind"] for d in docs}
    assert "Job" in kinds, "grafana-postsync.yaml missing Job"
    assert "ServiceAccount" in kinds, "grafana-postsync.yaml missing ServiceAccount"
    assert "Role" in kinds, "grafana-postsync.yaml missing Role"
    assert "RoleBinding" in kinds, "grafana-postsync.yaml missing RoleBinding"
    job = next(d for d in docs if d["kind"] == "Job")
    annotations = job["metadata"].get("annotations", {})
    assert annotations.get("argocd.argoproj.io/hook") == "PostSync"
    assert annotations.get("argocd.argoproj.io/hook-delete-policy") == "BeforeHookCreation"


def test_gitops_grafana_dashboards_configmap(repo_root: Path):
    """Dashboards ConfigMap must contain all expected dashboard JSON files."""
    docs = _load_docs(repo_root / GITOPS_NS / "grafana-dashboards.yaml")
    cm = next(d for d in docs if d["kind"] == "ConfigMap")
    assert cm["metadata"]["name"] == "grafana-dashboards"
    expected_dashboards = {
        "grafana-audit-security.json",
        "grafana-loki-profiler.json",
        "grafana-node-cluster-health.json",
        "grafana-ops-overview.json",
        "grafana-platform-operators.json",
    }
    actual_keys = set(cm["data"].keys())
    assert expected_dashboards == actual_keys, f"Missing dashboards: {expected_dashboards - actual_keys}"


def test_gitops_sp_overlay_exists(repo_root: Path):
    """SP overlay must exist (even as placeholder)."""
    docs = _load_docs(repo_root / GITOPS_NS / "loki-config-sp-overlay.yaml")
    cm = next(d for d in docs if d["kind"] == "ConfigMap")
    assert cm["metadata"]["name"] == "logging-loki-config"
    assert cm["metadata"]["namespace"] == "openshift-logging"


def test_gitops_storage_secret_template(repo_root: Path):
    """storage-secret.yaml must be a ytt template with Vault-sourced conditional."""
    content = (repo_root / GITOPS_NS / "storage-secret.yaml").read_text()
    assert "base64.encode" in content, "must use base64.encode for Secret data"
    assert 'azure.account_name != ""' in content, "must guard on account_name"
    assert "logging-loki-azure" in content, "must target the logging-loki-azure secret"
    assert "client_id" in content, "must support SP auth fields"
    assert "account_key" in content, "must support standard auth fields"
    assert "loki_storage" in content, "must use loki_storage values key"
    assert 'data.values.envs[0].name + "-audit-loki"' in content, \
        "empty container must default to {cluster}-audit-loki"


def test_gitops_grafana_secret_template(repo_root: Path):
    """grafana-secret.yaml must conditionally render admin credentials."""
    content = (repo_root / GITOPS_NS / "grafana-secret.yaml").read_text()
    assert "base64.encode" in content, "must use base64.encode for Secret data"
    assert 'GF_SECURITY_ADMIN_USER: "(@=' in content, "Secret data values must be YAML strings"
    assert 'GF_SECURITY_ADMIN_PASSWORD: "(@=' in content, "Secret data values must be YAML strings"
    assert 'grafana_admin_password != ""' in content, "must guard on grafana_admin_password"
    assert "grafana-admin-credentials" in content, "must target grafana-admin-credentials"
    assert "loki_storage" in content, "must use loki_storage values key"


def test_gitops_values_secrets_schema(repo_root: Path):
    """values.yaml must include both secrets.azure (Conjur) and secrets.loki_storage (Loki)."""
    content = (repo_root / GITOPS_NS / "values.yaml").read_text()
    assert "secrets:" in content, "values.yaml must have secrets section"
    assert "loki_storage:" in content, "values.yaml must have secrets.loki_storage section"
    assert 'account_name: ""' in content, "account_name must default to empty"
    assert 'grafana_admin_password: ""' in content, "grafana_admin_password must default to empty"
    assert "Storage Blob Data Contributor" in content or "blob storage" in content, \
        "must clarify credentials are storage-scoped"
    # Conjur CMP sidecar injects ALL platform secrets — every section must exist
    # in the base schema or ytt overlay matching fails. See values.yaml comments.
    conjur_sections = [
        "azure:", "redhat:", "dynatrace:", "cloudability:",
        "ldap:", "prisma:", "ssh:", "nexus:", "ssl:", "kubeconfig:",
    ]
    for section in conjur_sections:
        assert section in content, f"values.yaml must have secrets.{section.rstrip(':')} for Conjur overlay"
    assert 'spn: ""' in content, "secrets.azure must include spn key"
    assert "log_analytics:" in content, "secrets.azure must include log_analytics"
    assert 'workspace_shared_key: ""' in content, "log_analytics must include workspace_shared_key"


def test_gitops_values_vault_config_keys(repo_root: Path):
    """loki_storage must include all Vault-driven configuration keys."""
    values = yaml.safe_load((repo_root / GITOPS_NS / "values.yaml").read_text())
    ls = values["secrets"]["loki_storage"]
    required_keys = [
        "account_name", "account_key", "container", "environment",
        "client_id", "client_secret", "tenant_id",
        "grafana_admin_password", "grafana_image",
        "lokistack_size", "management_state", "storage_class",
        "requests_cpu", "requests_memory", "limits_memory",
        "rbac_edit", "rbac_view", "deployment_id",
    ]
    for key in required_keys:
        assert key in ls, f"secrets.loki_storage.{key} missing from values.yaml"
    assert ls["lokistack_size"] == "1x.small", "lokistack_size default must be 1x.small"
    assert ls["management_state"] == "Managed", "management_state default must be Managed"
    assert ls["storage_class"] == "managed-csi", "storage_class default must be managed-csi"


def test_gitops_lokistack_vault_driven(repo_root: Path):
    """lokistack.yaml must read size, managementState, storageClassName from loki_storage."""
    content = (repo_root / GITOPS_NS / "lokistack.yaml").read_text()
    assert "ls.management_state" in content, \
        "lokistack.yaml must read managementState from loki_storage"
    assert "ls.lokistack_size" in content, \
        "lokistack.yaml must read size from loki_storage"
    assert "ls.storage_class" in content, \
        "lokistack.yaml must read storageClassName from loki_storage"


def test_gitops_grafana_image_vault_driven(repo_root: Path):
    """grafana.yaml must read container image from loki_storage.grafana_image."""
    content = (repo_root / GITOPS_NS / "grafana.yaml").read_text()
    assert "grafana_img" in content, \
        "grafana.yaml must define grafana_img from loki_storage.grafana_image"
    assert "grafana/grafana:latest" in content, \
        "grafana.yaml must fall back to grafana/grafana:latest"


def test_gitops_storage_secret_always_has_account_key(repo_root: Path):
    """storage-secret.yaml must always render account_key (double-base64 dummy if empty)."""
    content = (repo_root / GITOPS_NS / "storage-secret.yaml").read_text()
    assert 'base64.encode(base64.encode("unused"))' in content, \
        "empty account_key must be double-base64 before the Secret data encoding"


def test_gitops_sp_overlay_text_templating(repo_root: Path):
    """loki-config-sp-overlay.yaml must use text-templated-strings, not raw #@ in literal blocks."""
    content = (repo_root / GITOPS_NS / "loki-config-sp-overlay.yaml").read_text()
    assert "@yaml/text-templated-strings" in content, \
        "must use @yaml/text-templated-strings for config.yaml interpolation"
    assert "(@= azure." in content, \
        "must use (@= expr @) syntax inside literal block"


def test_gitops_postsync_no_pipe_hang(repo_root: Path):
    """grafana-postsync.yaml Step 3 must not pipe oc create into oc apply."""
    content = (repo_root / GITOPS_NS / "grafana-postsync.yaml").read_text()
    assert "oc apply -f -" not in content, \
        "grafana-postsync.yaml must not pipe into 'oc apply -f -' (use temp file instead)"
