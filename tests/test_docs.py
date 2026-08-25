"""LogQL docs cover the security queries called out in the quickstart."""

from pathlib import Path


def test_logql_cheatsheet_topics(repo_root: Path):
    text = (repo_root / "docs" / "logql-queries.md").read_text(encoding="utf-8")
    for needle in (
        'verb="delete"',
        "clusterrolebindings",
        "401",
        "403",
        'verb="impersonate"',
        "{log_type=",
    ):
        assert needle in text, f"missing {needle}"


def test_azure_blob_request_doc(repo_root: Path):
    text = (repo_root / "docs" / "azure-blob-request.md").read_text(encoding="utf-8")
    for needle in (
        "StorageV2",
        "Standard_LRS",
        "account_name",
        "account_key",
        "logging-loki-azure",
        "azure-cloud-credentials",
        "Hierarchical namespace",
    ):
        assert needle in text, f"missing {needle}"
