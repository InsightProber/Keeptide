#!/usr/bin/env python3

import json
import math
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
REPORT_SCRIPT = REPOSITORY_ROOT / "scripts" / "validate_benchmark_report.py"
CURRENT_SHA = "1f415972edbada97c671746f30b423dfc171a5c8"
CATEGORIES = ("cjk3", "ascii3", "short", "miss")


def valid_payload() -> dict[str, object]:
    payload: dict[str, object] = {
        "schema_version": 1,
        "configuration": "Release",
        "commit_sha": CURRENT_SHA,
        "machine": "Mac15,7 / Apple M2 Pro",
        "toolchain": "Xcode 26.0 / Swift 6.2",
        "requested_items": 100_000,
        "initial_items": 100_000,
        "final_items": 100_017,
        "seed": 7,
        "query_runs_per_category": 20,
        "rebuild_ms": 12_345.5,
        "index_bytes": 9_876_543,
        "commits_during_rebuild": 17,
        "commit_latency_samples": 17,
        "commit_p95_ms": 4.5,
        "short_sql_scan_p95_ms": 30.0,
        "first_batch_gate_ms": 150.0,
        "gate_scope": "SearchService first batch only; not UI presentation latency",
    }
    for category in CATEGORIES:
        payload[f"{category}_first_p50_ms"] = 20.0
        payload[f"{category}_first_p95_ms"] = 40.0
        payload[f"{category}_full_p50_ms"] = 45.0
        payload[f"{category}_full_p95_ms"] = 80.0
        payload[f"{category}_max_matches"] = 0 if category == "miss" else 12
    return payload


class BenchmarkReportTests(unittest.TestCase):
    def run_validator(self, payload: dict[str, object] | None, *, expected_sha: str = CURRENT_SHA):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "benchmark.log"
            output = root / "report.json"
            benchmark_line = ("KEEPTIDE_SEARCH_BENCHMARK " + json.dumps(payload, allow_nan=True) + "\n"
                              if payload is not None else "")
            log.write_text("unrelated build output\n" + benchmark_line, encoding="utf-8")
            result = subprocess.run(
                [
                    "python3", str(REPORT_SCRIPT),
                    "--log", str(log),
                    "--output", str(output),
                    "--expected-sha", expected_sha,
                    "--expected-items", "100000",
                    "--oracle-items", "10000",
                ],
                cwd=REPOSITORY_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            report = json.loads(output.read_text()) if output.exists() else None
            return result, report

    def test_valid_release_report_records_provenance_and_gate_scope(self):
        result, report = self.run_validator(valid_payload())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["oracle_items"], 10_000)
        self.assertTrue(report["first_batch_gate_passed"])
        self.assertIn("not UI", report["gate_scope"])

    def test_debug_report_cannot_pass_as_release(self):
        payload = valid_payload()
        payload["configuration"] = "Debug"

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release", result.stderr)

    def test_unrecorded_provenance_cannot_pass(self):
        payload = valid_payload()
        payload["machine"] = "unrecorded"

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("machine", result.stderr)

    def test_missing_benchmark_line_cannot_pass_as_an_unrun_benchmark(self):
        result, _ = self.run_validator(None)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 0", result.stderr)

    def test_stale_sha_cannot_pass_as_current(self):
        result, _ = self.run_validator(valid_payload(), expected_sha="2" * 40)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA", result.stderr)

    def test_missing_metric_cannot_pass(self):
        payload = valid_payload()
        del payload["short_full_p50_ms"]

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("short_full_p50_ms", result.stderr)

    def test_non_finite_metric_cannot_pass(self):
        payload = valid_payload()
        payload["cjk3_first_p95_ms"] = math.nan

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("finite", result.stderr)

    def test_final_item_count_must_include_successful_rebuild_commits(self):
        payload = valid_payload()
        payload["final_items"] = 100_016

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("final_items", result.stderr)

    def test_requested_item_count_is_required(self):
        payload = valid_payload()
        del payload["requested_items"]

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requested_items", result.stderr)

    def test_observed_initial_count_must_match_the_requested_fixture(self):
        payload = valid_payload()
        payload["initial_items"] = 99_999
        payload["final_items"] = 100_016

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("initial_items", result.stderr)

    def test_zero_rebuild_commit_samples_cannot_produce_a_passing_zero_latency(self):
        payload = valid_payload()
        payload["commits_during_rebuild"] = 0
        payload["commit_latency_samples"] = 0
        payload["commit_p95_ms"] = 0
        payload["final_items"] = payload["initial_items"]

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("commits_during_rebuild", result.stderr)

    def test_commit_latency_sample_count_must_match_successful_commits(self):
        payload = valid_payload()
        payload["commit_latency_samples"] = 16

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("commit_latency_samples", result.stderr)

    def test_service_first_batch_p95_above_gate_fails(self):
        payload = valid_payload()
        payload["ascii3_first_p95_ms"] = 150.01

        result, _ = self.run_validator(payload)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("first-batch", result.stderr)


if __name__ == "__main__":
    unittest.main()
