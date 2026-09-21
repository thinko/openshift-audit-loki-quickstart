"""load-cluster-env.sh fills variables from vault, overlays, and defaults."""

import os
import subprocess
from pathlib import Path


def _write_fixture(root: Path) -> None:
    overlay = root / "_overlays" / "arod08"
    overlay.mkdir(parents=True)
    (overlay / "values.yaml").write_text(
        "\n".join(
            [
                "secrets:",
                "  loki_storage:",
                '    account_name: ""',
                '    container: "from-values"',
                '    environment: "AzureChinaCloud"',
                '    client_id: ""',
                "envs:",
                "  - name: arod08",
                "    rbac:",
                "      edit: from-values-edit",
                "      view: from-values-view",
                "    deployment_id: from-values-deploy",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (overlay / "gitops-secrets-loki-storage.yaml").write_text(
        "\n".join(
            [
                "#! fragment",
                "  loki_storage:",
                '    account_name: "from-secrets"',
                '    client_id: "from-secrets-id"',
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    customer = root / "_overlays" / "_customer"
    customer.mkdir(parents=True)
    (customer / "values-base.yaml").write_text(
        'grafana_image: "from-customer"\nrbac:\n  edit: ""\n  view: "from-customer-view"\n',
        encoding="utf-8",
    )


def _fake_bin(root: Path) -> Path:
    bindir = root / "bin"
    bindir.mkdir(exist_ok=True)
    safe = bindir / "safe"
    safe.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' '--- # secret/test/arod08/loki-storage' "
        "'account_name: fromvault' 'client_secret: vault secret'\n",
        encoding="utf-8",
    )
    safe.chmod(0o755)
    az = bindir / "az"
    az.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    az.chmod(0o755)
    return bindir


def _run(repo_root: Path, tmp: Path, *args: str, env_extra: dict | None = None):
    script = repo_root / "scripts" / "load-cluster-env.sh"
    env = {
        "PATH": f"{_fake_bin(tmp)}:{os.environ.get('PATH', '')}",
        "HOME": str(tmp),
    }
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", str(script), "--root", str(tmp), *args],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def _source_line(stderr: str, name: str) -> str:
    for line in stderr.splitlines():
        if line.startswith(name + " ") or line.startswith(name + "\t"):
            return line
    raise AssertionError(f"{name} missing from report:\n{stderr}")


def test_precedence_and_hidden_values(repo_root: Path, tmp_path: Path):
    _write_fixture(tmp_path)
    result = _run(repo_root, tmp_path, "--cluster", "arod08", "--vault-base", "secret/test")
    assert result.returncode == 0, result.stderr
    assert "fromvault" not in result.stderr
    assert "vault secret" not in result.stderr
    assert "vault" in _source_line(result.stderr, "AZURE_STORAGE_ACCOUNT_NAME")
    assert "overlay values" in _source_line(result.stderr, "AZURE_CONTAINER_NAME")
    assert "overlay secrets" in _source_line(result.stderr, "AZURE_SP_CLIENT_ID")
    assert "customer base" in _source_line(result.stderr, "GRAFANA_IMAGE")
    assert "default" in _source_line(result.stderr, "AZURE_STORAGE_ACCOUNT_KEY")
    assert "unset" in _source_line(result.stderr, "GRAFANA_ADMIN_PASSWORD")
    assert "export AZURE_STORAGE_ACCOUNT_NAME=fromvault" in result.stdout
    assert "export AZURE_CONTAINER_NAME=from-values" in result.stdout


def test_show_values_set_and_skip(repo_root: Path, tmp_path: Path):
    _write_fixture(tmp_path)
    result = _run(
        repo_root,
        tmp_path,
        "--cluster",
        "AROD08",
        "--vault-base",
        "secret/test",
        "--show-values",
        "--set",
        "AZURE_ENVIRONMENT=AzureUSGovernment",
        "--skip",
        "AZURE_SP_CLIENT_ID",
        env_extra={"AZURE_SP_CLIENT_SECRET": "fromenv"},
    )
    assert result.returncode == 0, result.stderr
    assert "fromenv" in _source_line(result.stderr, "AZURE_SP_CLIENT_SECRET")
    assert "environment" in _source_line(result.stderr, "AZURE_SP_CLIENT_SECRET")
    assert "command line" in _source_line(result.stderr, "AZURE_ENVIRONMENT")
    assert "AzureUSGovernment" in _source_line(result.stderr, "AZURE_ENVIRONMENT")
    assert "skipped" in _source_line(result.stderr, "AZURE_SP_CLIENT_ID")
    assert "unset AZURE_SP_CLIENT_ID" in result.stdout
    assert "export CLUSTER=arod08" in result.stdout
    assert "ZFc1MWMyVms=" in _source_line(result.stderr, "AZURE_STORAGE_ACCOUNT_KEY")


def test_gitops_dir_beats_overlay_and_ignores_placeholders(repo_root: Path, tmp_path: Path):
    _write_fixture(tmp_path)
    gitops = tmp_path / "internal" / "namespaces" / "openshift-logging"
    gitops.mkdir(parents=True)
    (gitops / "values.yaml").write_text(
        "\n".join(
            [
                "secrets:",
                "  loki_storage:",
                '    container: "from-gitops"',
                '    storage_class: "from-gitops-sc"',
                "envs:",
                "  - name: arod08",
                "    rbac:",
                "      edit: from-gitops-edit",
                "      view: REPLACE_ME_VIEW",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    repo_gitops = tmp_path / "gitops" / "namespaces" / "openshift-logging"
    repo_gitops.mkdir(parents=True)
    (repo_gitops / "values.yaml").write_text(
        'secrets:\n  loki_storage:\n    storage_class: "from-repo-gitops"\n',
        encoding="utf-8",
    )
    result = _run(
        repo_root,
        tmp_path,
        "--cluster",
        "arod08",
        "--vault-base",
        "secret/test",
        "--gitops-dir",
        str(gitops),
        "--show-values",
    )
    assert result.returncode == 0, result.stderr
    assert "from-gitops" in _source_line(result.stderr, "AZURE_CONTAINER_NAME")
    assert "gitops values" in _source_line(result.stderr, "AZURE_CONTAINER_NAME")
    assert "from-gitops-edit" in _source_line(result.stderr, "RBAC_EDIT")
    assert "from-values-view" in _source_line(result.stderr, "RBAC_VIEW")
    assert "from-gitops-sc" in _source_line(result.stderr, "STORAGE_CLASS")

    repo_only = _run(
        repo_root,
        tmp_path,
        "--cluster",
        "arod08",
        "--vault-base",
        "secret/test",
        "--show-values",
    )
    assert repo_only.returncode == 0, repo_only.stderr
    assert "from-values" in _source_line(repo_only.stderr, "AZURE_CONTAINER_NAME")
    assert "from-repo-gitops" in _source_line(repo_only.stderr, "STORAGE_CLASS")
    assert "repo gitops values" in _source_line(repo_only.stderr, "STORAGE_CLASS")


def test_sourced_export(repo_root: Path, tmp_path: Path):
    _write_fixture(tmp_path)
    script = repo_root / "scripts" / "load-cluster-env.sh"
    bindir = _fake_bin(tmp_path)
    probe = tmp_path / "probe.sh"
    probe.write_text(
        "\n".join(
            [
                "#!/bin/bash",
                f"source '{script}'",
                "load_cluster_env --cluster arod08 "
                f"--root '{tmp_path}' --vault-base secret/test --skip AZURE_SP_CLIENT_SECRET",
                'printf "name=%s\\n" "$AZURE_STORAGE_ACCOUNT_NAME"',
                'printf "container=%s\\n" "$AZURE_CONTAINER_NAME"',
                'if [ "${AZURE_SP_CLIENT_SECRET+x}" = x ]; then printf "secret=set\\n"; else printf "secret=unset\\n"; fi',
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["bash", str(probe)],
        check=False,
        capture_output=True,
        text=True,
        env={"PATH": f"{bindir}:{os.environ.get('PATH', '')}", "HOME": str(tmp_path)},
    )
    assert result.returncode == 0, result.stderr
    assert "name=fromvault" in result.stdout
    assert "container=from-values" in result.stdout
    assert "secret=unset" in result.stdout
