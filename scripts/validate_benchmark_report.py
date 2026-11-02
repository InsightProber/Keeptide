#!/usr/bin/env python3
"""Validate one Release search benchmark line and write its durable JSON report."""

import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import sys
from typing import NoReturn


PREFIX = "KEEPTIDE_SEARCH_BENCHMARK "
CATEGORIES = ("cjk3", "ascii3", "short", "miss")
LATENCY_SUFFIXES = ("first_p50_ms", "first_p95_ms", "full_p50_ms", "full_p95_ms")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


class InvalidReport(ValueError):
    pass


def fail(message: str) -> NoReturn:
    raise InvalidReport(message)


def integer(report: dict[str, object], key: str, *, minimum: int = 0) -> int:
    value = report.get(key)
    if type(value) is not int or value < minimum:
        fail(f"{key} must be an integer >= {minimum}")
    return value


def finite_number(report: dict[str, object], key: str) -> float:
    value = report.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        fail(f"{key} must be a finite number")
    if value < 0:
        fail(f"{key} must not be negative")
    return float(value)


def text(report: dict[str, object], key: str) -> str:
    value = report.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{key} must be a non-empty string")
    return value


def provenance_text(report: dict[str, object], key: str) -> str:
    value = text(report, key)
    if value.strip().lower() == "unrecorded":
        fail(f"{key} provenance must be recorded")
    return value


def parse_report(log_path: Path) -> dict[str, object]:
    lines = [line.removeprefix(PREFIX) for line in log_path.read_text(encoding="utf-8").splitlines()
             if line.startswith(PREFIX)]
    if len(lines) != 1:
        fail(f"expected exactly one {PREFIX.strip()} line, found {len(lines)}")
    try:
        value = json.loads(lines[0], parse_constant=lambda constant: fail(f"non-finite value {constant}"))
    except json.JSONDecodeError as error:
        fail(f"benchmark JSON is invalid: {error}")
    if not isinstance(value, dict):
        fail("benchmark JSON must be an object")
    return value


def validate(report: dict[str, object], expected_sha: str, expected_items: int, oracle_items: int) -> None:
    if report.get("schema_version") != 1:
        fail("schema_version must be 1")
    if report.get("configuration") != "Release":
        fail("configuration must be Release; Debug measurements cannot pass")
    if not SHA_PATTERN.fullmatch(expected_sha):
        fail("expected SHA must be a full 40-character lowercase Git SHA")
    if text(report, "commit_sha") != expected_sha:
        fail("benchmark SHA does not match the current expected SHA")
    provenance_text(report, "machine")
    provenance_text(report, "toolchain")
    requested_items = integer(report, "requested_items", minimum=1)
    if requested_items != expected_items:
        fail(f"requested_items must equal configured count {expected_items}")
    initial_items = integer(report, "initial_items", minimum=1)
    if initial_items != requested_items:
        fail("initial_items observed in the store must equal requested_items")
    commits = integer(report, "commits_during_rebuild", minimum=1)
    commit_samples = integer(report, "commit_latency_samples", minimum=1)
    if commit_samples != commits:
        fail("commit_latency_samples must equal successful commits_during_rebuild")
    if integer(report, "final_items", minimum=1) != initial_items + commits:
        fail("final_items must equal initial_items plus successful commits_during_rebuild")
    if integer(report, "seed") != 7:
        fail("seed must be 7")
    if integer(report, "query_runs_per_category", minimum=1) != 20:
        fail("query_runs_per_category must be 20")
    if oracle_items != 10_000:
        fail("oracle_items must be fixed at 10000")

    for key in ("rebuild_ms", "index_bytes", "commit_p95_ms", "short_sql_scan_p95_ms"):
        finite_number(report, key)
    gate = finite_number(report, "first_batch_gate_ms")
    if gate != 150.0:
        fail("first_batch_gate_ms must be 150")
    scope = text(report, "gate_scope")
    if "SearchService" not in scope or "not UI" not in scope:
        fail("gate_scope must identify SearchService first-batch timing and state that it is not UI latency")

    over_gate: list[str] = []
    for category in CATEGORIES:
        for suffix in LATENCY_SUFFIXES:
            value = finite_number(report, f"{category}_{suffix}")
            if suffix == "first_p95_ms" and value > gate:
                over_gate.append(f"{category}={value:g}ms")
        count = integer(report, f"{category}_max_matches")
        if category != "miss" and count == 0:
            fail(f"{category}_max_matches must be greater than zero")
    if over_gate:
        fail("SearchService first-batch p95 exceeded 150ms: " + ", ".join(over_gate))


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--expected-items", required=True, type=int)
    parser.add_argument("--oracle-items", required=True, type=int)
    return parser.parse_args()


def main() -> int:
    options = arguments()
    try:
        report = parse_report(options.log)
        validate(report, options.expected_sha, options.expected_items, options.oracle_items)
        report["oracle_items"] = options.oracle_items
        report["first_batch_gate_passed"] = True
        report["validated_at_utc"] = datetime.now(timezone.utc).isoformat()
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (InvalidReport, OSError) as error:
        print(f"Benchmark report rejected: {error}", file=sys.stderr)
        return 1
    print(f"Validated Release search benchmark: {options.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
