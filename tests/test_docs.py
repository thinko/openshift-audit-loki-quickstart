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
