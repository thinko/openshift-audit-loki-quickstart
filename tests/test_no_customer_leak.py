"""Reject customer-specific names and real-looking secrets in the public tree."""

from pathlib import Path

import pytest

FORBIDDEN = (
    "REDACTED_CUSTOMER",
    "REDACTED_DOMAIN",
    "REDACTED_CLUSTER",
    "REDACTED_ORG",
    "REDACTED_ORG",
    "REDACTED_DOMAIN",
)

SKIP_DIRS = {
    ".git",
    ".venv",
    "venv",
    "__pycache__",
    ".pytest_cache",
    "graphify-out",
    "tests",
    "_dev_docs",
    "_dev_tests_",
}

TEXT_SUFFIXES = {
    ".md",
    ".yml",
    ".yaml",
    ".sh",
    ".tpl",
    ".txt",
    ".py",
    ".gitignore",
    ".yaml",
}


def _iter_files(root: Path):
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.name in {"LICENSE"}:
            continue
        yield path


def test_no_customer_environment_references(repo_root: Path):
    hits: list[str] = []
    for path in _iter_files(repo_root):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        lower = text.lower()
        for token in FORBIDDEN:
            if token in lower:
                hits.append(f"{path.relative_to(repo_root)}: {token}")
    assert hits == [], "Public tree must not mention customer environments:\n" + "\n".join(hits)


def test_secret_template_keeps_placeholders(repo_root: Path):
    template = (repo_root / "manifests" / "02-storage-secret.template.yaml").read_text(
        encoding="utf-8"
    )
    for needle in (
        "<AZURE_STORAGE_ACCOUNT_NAME>",
        "<AZURE_STORAGE_ACCOUNT_KEY>",
        "<CONTAINER_NAME>",
    ):
        assert needle in template, f"missing placeholder {needle}"


def test_filled_secret_is_not_committed(repo_root: Path):
    assert not (repo_root / "manifests" / "02-storage-secret.yaml").exists()
