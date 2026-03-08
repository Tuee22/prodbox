"""Unit tests for documentation lint guard."""

from __future__ import annotations

from pathlib import Path

from prodbox.lib.lint.doc_lint_guard import IntentRule, find_doc_lint_violations


def _write(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def test_doc_lint_guard_accepts_valid_links_and_intent_ownership(tmp_path: Path) -> None:
    """Guard should pass with valid anchors and canonical intent ownership."""
    repo_root = tmp_path / "repo"
    readme = _write(
        repo_root / "README.md",
        "# Root\n\nSee [Details](documents/policy.md#rule-one).\n",
    )
    policy = _write(
        repo_root / "documents" / "policy.md",
        "# Policy\n\n## Rule One\n\nCanonical doctrine statement.\n",
    )
    intent_rule = IntentRule(
        name="sample",
        statement="Canonical doctrine statement.",
        canonical_docs=frozenset({Path("documents/policy.md")}),
    )
    violations = find_doc_lint_violations(
        repo_root,
        target_files=(readme, policy),
        intent_rules=(intent_rule,),
    )
    assert violations == ()


def test_doc_lint_guard_flags_missing_anchor(tmp_path: Path) -> None:
    """Guard should reject internal links that reference missing anchors."""
    repo_root = tmp_path / "repo"
    readme = _write(
        repo_root / "README.md",
        "# Root\n\nSee [Details](documents/policy.md#missing-anchor).\n",
    )
    policy = _write(repo_root / "documents" / "policy.md", "# Policy\n\n## Rule One\n\nText\n")
    intent_rule = IntentRule(
        name="sample",
        statement="Text",
        canonical_docs=frozenset({Path("documents/policy.md")}),
    )
    violations = find_doc_lint_violations(
        repo_root,
        target_files=(readme, policy),
        intent_rules=(intent_rule,),
    )
    assert len(violations) == 1
    assert "Missing anchor" in violations[0].reason


def test_doc_lint_guard_flags_intent_statement_outside_canonical_owner(tmp_path: Path) -> None:
    """Guard should reject doctrine statements duplicated in non-canonical docs."""
    repo_root = tmp_path / "repo"
    statement = "Doctrine statement owned by canonical doc."
    readme = _write(repo_root / "README.md", f"# Root\n\n{statement}\n")
    policy = _write(repo_root / "documents" / "policy.md", f"# Policy\n\n{statement}\n")
    intent_rule = IntentRule(
        name="sample",
        statement=statement,
        canonical_docs=frozenset({Path("documents/policy.md")}),
    )
    violations = find_doc_lint_violations(
        repo_root,
        target_files=(readme, policy),
        intent_rules=(intent_rule,),
    )
    assert len(violations) == 1
    assert "outside canonical owner" in violations[0].reason
