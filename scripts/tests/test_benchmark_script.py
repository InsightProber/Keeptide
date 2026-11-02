#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
BENCHMARK_SCRIPT = REPOSITORY_ROOT / "scripts" / "benchmark.sh"
CURRENT_SHA = "1f415972edbada97c671746f30b423dfc171a5c8"


class BenchmarkScriptTests(unittest.TestCase):
    def fake_tools(self, root: Path) -> tuple[dict[str, str], Path]:
        developer = root / "Xcode.app/Contents/Developer"
        developer.mkdir(parents=True)
        binaries = root / "bin"
        binaries.mkdir()
        capture = root / "calls.txt"

        xcodebuild = binaries / "xcodebuild"
        xcodebuild.write_text(
            """#!/bin/sh
if [ "$1" = "-version" ]; then printf 'Xcode 26.0\\nBuild version 17A1\\n'; exit 0; fi
{
  printf 'CALL runner_count=%s runner_oracle=%s runner_sha=%s runner_config=%s raw_count=%s raw_oracle=%s\\n' "${TEST_RUNNER_KEEPTIDE_SEARCH_BENCHMARK_COUNT:-}" "${TEST_RUNNER_KEEPTIDE_SEARCH_ORACLE_COUNT:-}" "${TEST_RUNNER_KEEPTIDE_BENCHMARK_COMMIT_SHA:-}" "${TEST_RUNNER_KEEPTIDE_BENCHMARK_CONFIGURATION:-}" "${KEEPTIDE_SEARCH_BENCHMARK_COUNT:-}" "${KEEPTIDE_SEARCH_ORACLE_COUNT:-}"
  printf '%s\\n' "$@"
} >> "$CAPTURE_PATH"
case " $* " in
  *" SearchPerformanceTests "*|*"-only-testing:KeeptideTests/SearchPerformanceTests"*)
    python3 - <<'PY'
import json, os
count = int(os.environ["TEST_RUNNER_KEEPTIDE_SEARCH_BENCHMARK_COUNT"])
p = {"schema_version":1,"configuration":"Release","commit_sha":os.environ["TEST_RUNNER_KEEPTIDE_BENCHMARK_COMMIT_SHA"],
     "machine":os.environ["TEST_RUNNER_KEEPTIDE_BENCHMARK_MACHINE"],"toolchain":os.environ["TEST_RUNNER_KEEPTIDE_BENCHMARK_TOOLCHAIN"],
     "requested_items":count,"initial_items":count,"final_items":count + 1,"seed":7,
     "query_runs_per_category":20,"rebuild_ms":100.0,"index_bytes":1000,"commits_during_rebuild":1,
     "commit_latency_samples":1,"commit_p95_ms":0.5,"short_sql_scan_p95_ms":1.0,
     "first_batch_gate_ms":150.0,"gate_scope":"SearchService first batch only; not UI presentation latency"}
for c in ("cjk3","ascii3","short","miss"):
    for suffix, value in (("first_p50_ms",1.0),("first_p95_ms",2.0),("full_p50_ms",3.0),("full_p95_ms",4.0)):
        p[f"{c}_{suffix}"] = value
    p[f"{c}_max_matches"] = 0 if c == "miss" else 1
print("KEEPTIDE_SEARCH_BENCHMARK " + json.dumps(p))
PY
    ;;
esac
""",
            encoding="utf-8",
        )
        xcrun = binaries / "xcrun"
        xcrun.write_text(
            """#!/bin/sh
if [ "$1" = "swiftc" ]; then printf 'Apple Swift version 6.2\\n'; exit 0; fi
printf '{"totalTestCount":1,"passedTests":1,"failedTests":0,"skippedTests":0,"result":"Passed"}\\n'
""",
            encoding="utf-8",
        )
        git = binaries / "git"
        git.write_text(
            f"""#!/bin/sh
if [ "$1" = "rev-parse" ]; then printf '{CURRENT_SHA}\\n'; exit 0; fi
if [ "$1" = "diff" ]; then exit 0; fi
if [ "$1" = "status" ]; then printf '%s' "${{FAKE_GIT_STATUS:-}}"; exit 0; fi
exit 2
""",
            encoding="utf-8",
        )
        sysctl = binaries / "sysctl"
        sysctl.write_text("#!/bin/sh\nprintf 'Mac15,7\\n'\n", encoding="utf-8")
        sw_vers = binaries / "sw_vers"
        sw_vers.write_text("#!/bin/sh\nprintf '26.0\\n'\n", encoding="utf-8")
        uname = binaries / "uname"
        uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")
        for executable in (xcodebuild, xcrun, git, sysctl, sw_vers, uname):
            executable.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            DEVELOPER_DIR=str(developer),
            PATH=f"{binaries}:{environment['PATH']}",
            CAPTURE_PATH=str(capture),
            KEEPTIDE_BENCHMARK_OUTPUT_ROOT=str(root / "results"),
        )
        return environment, capture

    def run_benchmark(self, *arguments: str, extra_environment: dict[str, str] | None = None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment, capture = self.fake_tools(root)
            environment.update(extra_environment or {})
            result = subprocess.run(
                [str(BENCHMARK_SCRIPT), *arguments],
                cwd=REPOSITORY_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            calls = capture.read_text(encoding="utf-8") if capture.exists() else ""
            reports = list((root / "results").rglob("report.json"))
            report = json.loads(reports[0].read_text()) if len(reports) == 1 else None
            return result, calls, report

    def test_default_runs_fixed_oracle_and_release_100k_benchmark(self):
        result, calls, report = self.run_benchmark()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner_oracle=10000", calls)
        self.assertIn("runner_count=100000", calls)
        self.assertIn("runner_config=Release", calls)
        self.assertIn("raw_count= raw_oracle=", calls)
        self.assertGreaterEqual(calls.count("Release"), 2)
        self.assertEqual(report["requested_items"], 100_000)
        self.assertEqual(report["initial_items"], 100_000)
        self.assertEqual(report["final_items"], 100_001)
        self.assertEqual(report["commit_latency_samples"], 1)
        self.assertEqual(report["commit_sha"], CURRENT_SHA)

    def test_million_item_run_requires_explicit_option(self):
        result, calls, report = self.run_benchmark("--million")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runner_count=1000000", calls)
        self.assertEqual(report["initial_items"], 1_000_000)

    def test_unknown_option_is_rejected_without_running_xcode(self):
        result, calls, report = self.run_benchmark("--large")

        self.assertEqual(result.returncode, 64)
        self.assertEqual(calls, "")
        self.assertIsNone(report)

    def test_untracked_source_cannot_produce_sha_attributed_evidence(self):
        result, calls, report = self.run_benchmark(
            extra_environment={"FAKE_GIT_STATUS": "?? Keeptide/Untracked.swift\\n"}
        )

        self.assertEqual(result.returncode, 65)
        self.assertIn("clean worktree", result.stderr)
        self.assertEqual(calls, "")
        self.assertIsNone(report)


if __name__ == "__main__":
    unittest.main()
