"""patch-loki-storage-config.sh rewrites only azure storage blocks."""

import os
import subprocess
from pathlib import Path

SAMPLE = """\
common:
  storage:
    azure:
      environment: AzureGlobal
      container_name: ${AZURE_CONTAINER_NAME}
      account_name: ${AZURE_STORAGE_ACCOUNT_NAME}
      account_key: ${AZURE_STORAGE_ACCOUNT_KEY}
limits_config:
  reject_old_samples: true
  ingestion_rate_mb: 4
storage_config:
  azure:
    account_name: ${AZURE_STORAGE_ACCOUNT_NAME}
    account_key: ${AZURE_STORAGE_ACCOUNT_KEY}
    endpoint_suffix: blob.core.windows.net
"""


def test_render_replaces_storage_blocks_and_keeps_the_rest(repo_root: Path):
    script = repo_root / "scripts" / "patch-loki-storage-config.sh"
    env = os.environ.copy()
    env.update(
        {
            "AZURE_ENVIRONMENT": "AzureGlobal",
            "AZURE_CONTAINER_NAME": "arod08-audit-loki",
            "AZURE_STORAGE_ACCOUNT_NAME": "acct",
            "AZURE_SP_CLIENT_ID": "cid",
            "AZURE_SP_CLIENT_SECRET": "s3cret/with:colon",
            "AZURE_SP_TENANT_ID": "tid",
        }
    )
    result = subprocess.run(
        ["bash", str(script), "--render"],
        input=SAMPLE,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "account_key" not in result.stdout
    assert "${AZURE_" not in result.stdout
    assert "reject_old_samples: true" in result.stdout
    assert "ingestion_rate_mb: 4" in result.stdout
    assert "endpoint_suffix: blob.core.windows.net" in result.stdout
    assert result.stdout.count("use_service_principal: true") == 2
    assert result.stdout.count("client_id: cid") == 2
    assert result.stdout.count("client_secret: s3cret/with:colon") == 2
    assert result.stdout.count("container_name: arod08-audit-loki") == 2
    assert "oc apply" not in result.stderr


def test_render_refuses_a_config_with_no_azure_storage(repo_root: Path):
    script = repo_root / "scripts" / "patch-loki-storage-config.sh"
    env = os.environ.copy()
    env.update(
        {
            "AZURE_ENVIRONMENT": "AzureGlobal",
            "AZURE_CONTAINER_NAME": "arod08-audit-loki",
            "AZURE_STORAGE_ACCOUNT_NAME": "acct",
            "AZURE_SP_CLIENT_ID": "cid",
            "AZURE_SP_CLIENT_SECRET": "s3cret",
            "AZURE_SP_TENANT_ID": "tid",
        }
    )
    result = subprocess.run(
        ["bash", str(script), "--render"],
        input="limits_config:\n  reject_old_samples: true\n",
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    assert result.returncode != 0
    assert "No azure storage block" in result.stderr
