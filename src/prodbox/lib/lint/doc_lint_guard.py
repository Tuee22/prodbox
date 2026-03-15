"""Documentation lint guard for internal links, anchors, and doctrine ownership."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_policy import repo_root

_LINK_PATTERN: re.Pattern[str] = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
_HEADER_PATTERN: re.Pattern[str] = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
_CODE_FENCE_PATTERN: re.Pattern[str] = re.compile(r"^\s*```")


@dataclass(frozen=True)
class IntentRule:
    """Canonical ownership rule for one doctrine statement."""

    name: str
    statement: str
    canonical_docs: frozenset[Path]


@dataclass(frozen=True)
class DocLintViolation:
    """One documentation lint violation."""

    relative_path: Path
    line_number: int
    reason: str


_INTENT_RULES: tuple[IntentRule, ...] = (
    IntentRule(
        name="command_output_contract",
        statement=(
            "Every CLI command must emit a deterministic execution summary; "
            "exit code alone is insufficient user output."
        ),
        canonical_docs=frozenset({Path("documents/engineering/effectful_dag_architecture.md")}),
    ),
    IntentRule(
        name="interpreter_runtime_parity",
        statement=(
            "DAG execution semantics must match BBY parity matrix: pending/ready loop, "
            "reduction handling, root-cause/skip outcomes, unexecuted reporting."
        ),
        canonical_docs=frozenset({Path("documents/engineering/effect_interpreter.md")}),
    ),
    IntentRule(
        name="rke2_lifecycle_orchestration",
        statement=(
            "RKE2 cluster provisioning is idempotently performed via eDAG lifecycle "
            "effects, not assumed pre-existing."
        ),
        canonical_docs=frozenset({Path("documents/engineering/prerequisite_doctrine.md")}),
    ),
    IntentRule(
        name="rke2_fail_fast_prerequisites",
        statement=(
            "Prerequisite nodes validate existence/readiness and fail fast with actionable "
            "fix hints; no silent auto-install in checks."
        ),
        canonical_docs=frozenset({Path("documents/engineering/prerequisite_doctrine.md")}),
    ),
    IntentRule(
        name="rke2_teardown_safety",
        statement=(
            "Cleanup must idempotently remove prodbox-annotated Kubernetes objects "
            "without deleting host storage paths used for persistent data."
        ),
        canonical_docs=frozenset({Path("documents/engineering/prerequisite_doctrine.md")}),
    ),
    IntentRule(
        name="retained_storage_rebinding",
        statement=(
            "Retained storage in prodbox is reconciled via static no-provisioner "
            "StorageClass and prebound PV/PVC resources to guarantee deterministic "
            "PVC->PV rebinding across cleanup/redeploy."
        ),
        canonical_docs=frozenset({Path("documents/engineering/storage_lifecycle_doctrine.md")}),
    ),
    IntentRule(
        name="partition_semantics_formal_proof",
        statement=(
            "Partition semantics for gateway leadership and DNS write gating must be "
            "formally verified by TLA+ before implementation changes are accepted."
        ),
        canonical_docs=frozenset(
            {Path("documents/engineering/distributed_gateway_architecture.md")}
        ),
    ),
    IntentRule(
        name="byzantine_formal_methods_primary",
        statement=(
            "For this Byzantine-generals-class failure mode, TLA+ model checking is "
            "the primary completeness tool; runtime tests validate model-to-code "
            "fidelity but are not exhaustive proofs."
        ),
        canonical_docs=frozenset(
            {Path("documents/engineering/distributed_gateway_architecture.md")}
        ),
    ),
    IntentRule(
        name="gateway_timing_contract",
        statement=(
            "Gateway timing contract is explicit: heartbeat_timeout_seconds in [3, 60], "
            "isolation_timeout_seconds = heartbeat_timeout_seconds, "
            "heartbeat_interval_seconds <= timeout/2, "
            "reconnect_interval_seconds <= timeout, and "
            "sync_interval_seconds <= timeout*2."
        ),
        canonical_docs=frozenset(
            {Path("documents/engineering/distributed_gateway_architecture.md")}
        ),
    ),
    IntentRule(
        name="tla_model_test_boundary",
        statement=(
            "The test suite cannot enumerate every partition/failure schedule; robust "
            "integration tests remain mandatory to validate TLA+ modelling choices "
            "against the implementation."
        ),
        canonical_docs=frozenset({Path("documents/engineering/unit_testing_policy.md")}),
    ),
    IntentRule(
        name="integration_runbook_enforcement",
        statement=(
            "When integration scope is selected, `prodbox test` must enforce the "
            "runbook by executing `prodbox rke2 ensure` before pytest."
        ),
        canonical_docs=frozenset({Path("documents/engineering/unit_testing_policy.md")}),
    ),
    IntentRule(
        name="prodtest_timeout_cap",
        statement=(
            "`prodbox test` phase-two pytest timeout budget is capped at 240 minutes "
            "(14,400 seconds)."
        ),
        canonical_docs=frozenset({Path("documents/engineering/unit_testing_policy.md")}),
    ),
    IntentRule(
        name="streaming_contract",
        statement=(
            "Streaming is observational only and must follow at-most-one-stream output "
            "serialization invariants."
        ),
        canonical_docs=frozenset({Path("documents/engineering/streaming_doctrine.md")}),
    ),
    IntentRule(
        name="test_skip_policy",
        statement=(
            "Skip/xfail is prohibited by default; any allowed exception requires explicit "
            "doctrinal criteria and automated enforcement."
        ),
        canonical_docs=frozenset({Path("documents/engineering/unit_testing_policy.md")}),
    ),
    IntentRule(
        name="purity_and_guardrails",
        statement=(
            "Side effects are interpreter-boundary only; policy guards in check-code are "
            "mandatory and blocking."
        ),
        canonical_docs=frozenset(
            {
                Path("documents/engineering/pure_fp_standards.md"),
                Path("documents/engineering/code_quality.md"),
            }
        ),
    ),
    IntentRule(
        name="check_code_gate",
        statement=(
            "poetry run prodbox check-code is the required single entrypoint for doctrine "
            "enforcement in local development."
        ),
        canonical_docs=frozenset({Path("README.md"), Path("AGENTS.md"), Path("CLAUDE.md")}),
    ),
    IntentRule(
        name="documentation_topology",
        statement=(
            "SSoT ownership, bidirectional links, and non-duplication rules are mandatory "
            "for all new doctrinal content."
        ),
        canonical_docs=frozenset(
            {
                Path("documents/documentation_standards.md"),
                Path("documents/engineering/README.md"),
            }
        ),
    ),
)


def find_doc_lint_violations(
    repo_path: Path,
    *,
    target_files: tuple[Path, ...] | None = None,
    intent_rules: tuple[IntentRule, ...] = _INTENT_RULES,
) -> tuple[DocLintViolation, ...]:
    """Find documentation lint violations."""
    markdown_files = (
        target_files if target_files is not None else _default_markdown_files(repo_path)
    )
    link_violations = _link_violations(repo_path, markdown_files)
    intent_violations = _intent_violations(repo_path, markdown_files, intent_rules=intent_rules)
    all_violations = sorted(
        (*link_violations, *intent_violations),
        key=_violation_sort_key,
    )
    return tuple(all_violations)


def _default_markdown_files(repo_path: Path) -> tuple[Path, ...]:
    docs_dir = repo_path / "documents"
    files: list[Path] = sorted(docs_dir.rglob("*.md")) if docs_dir.exists() else []
    for top_level in ("README.md", "CLAUDE.md", "AGENTS.md"):
        candidate = repo_path / top_level
        if candidate.exists():
            files.append(candidate)
    return tuple(sorted(files))


def _link_violations(
    repo_path: Path,
    markdown_files: tuple[Path, ...],
) -> tuple[DocLintViolation, ...]:
    anchor_cache: dict[Path, frozenset[str]] = {}
    violations: list[DocLintViolation] = []
    for markdown_file in markdown_files:
        source = markdown_file.read_text(encoding="utf-8")
        relative_path = markdown_file.relative_to(repo_path)
        in_code_fence = False
        for line_number, line in enumerate(source.splitlines(), start=1):
            if _CODE_FENCE_PATTERN.match(line):
                in_code_fence = not in_code_fence
                continue
            if in_code_fence:
                continue
            for link_target in _extract_markdown_links(line):
                if _is_external_link(link_target):
                    continue
                file_part, anchor = _split_link(link_target)
                target_file = _resolve_target(markdown_file, file_part=file_part)
                if not target_file.exists():
                    violations.append(
                        DocLintViolation(
                            relative_path=relative_path,
                            line_number=line_number,
                            reason=f"Broken internal link target: {link_target}",
                        )
                    )
                    continue
                if anchor is None:
                    continue
                anchors = anchor_cache.get(target_file)
                if anchors is None:
                    anchors = _collect_anchors(target_file)
                    anchor_cache[target_file] = anchors
                if anchor not in anchors:
                    violations.append(
                        DocLintViolation(
                            relative_path=relative_path,
                            line_number=line_number,
                            reason=f"Missing anchor '#{anchor}' in {target_file.relative_to(repo_path)}",
                        )
                    )
    return tuple(violations)


def _intent_violations(
    repo_path: Path,
    markdown_files: tuple[Path, ...],
    *,
    intent_rules: tuple[IntentRule, ...],
) -> tuple[DocLintViolation, ...]:
    contents: dict[Path, str] = {
        markdown_file.relative_to(repo_path): markdown_file.read_text(encoding="utf-8")
        for markdown_file in markdown_files
    }
    violations: list[DocLintViolation] = []

    for rule in intent_rules:
        found_files = tuple(path for path, content in contents.items() if rule.statement in content)
        canonical_hits = tuple(path for path in found_files if path in rule.canonical_docs)
        if not canonical_hits:
            owner = sorted(rule.canonical_docs, key=str)[0]
            violations.append(
                DocLintViolation(
                    relative_path=owner,
                    line_number=1,
                    reason=(
                        f"Missing doctrine statement '{rule.name}' in canonical owner " f"({owner})"
                    ),
                )
            )
        for found_file in found_files:
            if found_file in rule.canonical_docs:
                continue
            line_number = _line_number(contents[found_file], rule.statement)
            violations.append(
                DocLintViolation(
                    relative_path=found_file,
                    line_number=line_number,
                    reason=(f"Doctrine statement '{rule.name}' appears outside canonical owner(s)"),
                )
            )

    return tuple(violations)


def _extract_markdown_links(line: str) -> tuple[str, ...]:
    links: list[str] = []
    for link_match in _LINK_PATTERN.finditer(line):
        group_value = link_match.group(1)
        if isinstance(group_value, str):
            links.append(group_value.strip())
    return tuple(links)


def _is_external_link(link_target: str) -> bool:
    return link_target.startswith(("http://", "https://", "mailto:", "tel:"))


def _split_link(link_target: str) -> tuple[str, str | None]:
    if link_target.startswith("#"):
        return ("", link_target[1:])
    if "#" not in link_target:
        return (link_target, None)
    file_part, anchor = link_target.split("#", maxsplit=1)
    return (file_part, anchor)


def _resolve_target(source_file: Path, *, file_part: str) -> Path:
    if file_part == "":
        return source_file
    return (source_file.parent / file_part).resolve()


def _collect_anchors(markdown_file: Path) -> frozenset[str]:
    source = markdown_file.read_text(encoding="utf-8")
    counts: dict[str, int] = {}
    anchors: set[str] = set()
    in_code_fence = False
    for line in source.splitlines():
        if _CODE_FENCE_PATTERN.match(line):
            in_code_fence = not in_code_fence
            continue
        if in_code_fence:
            continue
        header = _parse_header(line)
        if header is None:
            continue
        anchor = _to_anchor(header)
        if anchor == "":
            continue
        count = counts.get(anchor, 0)
        resolved_anchor = anchor if count == 0 else f"{anchor}-{count}"
        counts[anchor] = count + 1
        anchors.add(resolved_anchor)
    return frozenset(anchors)


def _parse_header(line: str) -> str | None:
    header_match = _HEADER_PATTERN.match(line)
    if header_match is None:
        return None
    title = header_match.group(2)
    if not isinstance(title, str):
        return None
    return title.strip().rstrip("#").strip()


def _to_anchor(header: str) -> str:
    lowered = header.lower()
    without_backticks = lowered.replace("`", "")
    alnum = re.sub(r"[^a-z0-9\s-]", "", without_backticks)
    collapsed_spaces = re.sub(r"\s+", "-", alnum.strip())
    collapsed_dashes = re.sub(r"-+", "-", collapsed_spaces)
    return collapsed_dashes.strip("-")


def _line_number(content: str, needle: str) -> int:
    for index, line in enumerate(content.splitlines(), start=1):
        if needle in line:
            return index
    return 1


def _render_violation(violation: DocLintViolation) -> str:
    return f"{violation.relative_path}:{violation.line_number}: {violation.reason}"


def _violation_sort_key(violation: DocLintViolation) -> tuple[str, int, str]:
    return (str(violation.relative_path), violation.line_number, violation.reason)


def main() -> int:
    """Run documentation lint guard and return process exit code."""
    root = repo_root()
    violations = find_doc_lint_violations(root)
    if not violations:
        print("doc_lint_guard: PASS")
        return 0
    print("doc_lint_guard: FAIL", file=sys.stderr)
    for violation in violations:
        print(_render_violation(violation), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
