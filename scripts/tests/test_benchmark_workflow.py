#!/usr/bin/env python3

from pathlib import Path
import re
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPOSITORY_ROOT / ".github" / "workflows" / "benchmark.yml"


class BenchmarkWorkflowTests(unittest.TestCase):
    def workflow(self) -> str:
        self.assertTrue(WORKFLOW.is_file(), "Release benchmark workflow is missing")
        return WORKFLOW.read_text(encoding="utf-8")

    def test_workflow_runs_for_relevant_pull_requests_and_bounded_manual_choices(self):
        source = self.workflow()

        self.assertRegex(source, r"(?m)^on:\n  pull_request:\n    paths:\n")
        for path in (
            ".github/workflows/benchmark.yml",
            "scripts/benchmark.sh",
            "scripts/validate_benchmark_report.py",
            "KeeptideTests/SearchPerformanceTests.swift",
        ):
            self.assertIn(f"      - {path}", source)
        self.assertIn("  workflow_dispatch:", source)
        self.assertNotRegex(source, r"(?m)^  (?:push|schedule|pull_request_target):")
        self.assertRegex(source, r"(?ms)^      dataset:\n.*?        default: standard\n.*?        type: choice\n.*?        options:\n          - standard\n          - million\n")

    def test_workflow_tracks_every_production_input_used_by_the_search_benchmark(self):
        source = self.workflow()

        for path in (
            "Keeptide/Search/HistoryConsumer.swift",
            "Keeptide/Search/QueryNormalizer.swift",
            "Keeptide/Search/SQLiteSearchIndex.swift",
            "Keeptide/Search/SearchProjection.swift",
            "Keeptide/Search/SearchService.swift",
            "Keeptide/Persistence/ContentRepository.swift",
            "Keeptide/Persistence/LocalUsageStore.swift",
            "Keeptide/Persistence/PersistenceController.swift",
            "Keeptide/Persistence/StoreChangeReader.swift",
            "Keeptide/Persistence/StoreSafetyGate.swift",
            "Keeptide/Persistence/StoredRecords.swift",
            "Keeptide/Persistence/WriteCoordinator.swift",
        ):
            self.assertIn(f"      - {path}", source)

    def test_workflow_matches_ci_machine_toolchain_and_has_read_only_permissions(self):
        source = self.workflow()

        self.assertIn("runs-on: macos-26", source)
        self.assertIn("DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer", source)
        self.assertIn("timeout-minutes: 240", source)
        self.assertRegex(source, r"(?m)^permissions:\n  contents: read$")
        self.assertNotRegex(source, r"(?m)^\s+\w+: write$")

    def test_only_explicit_million_input_selects_the_million_item_command(self):
        source = self.workflow()

        self.assertIn('if [ "${{ github.event_name }}" = "workflow_dispatch" ] &&', source)
        self.assertIn('[ "${{ inputs.dataset }}" = "million" ]; then', source)
        self.assertEqual(source.count("./scripts/benchmark.sh --million"), 1)
        self.assertRegex(source, r"(?m)^\s+else\n\s+\./scripts/benchmark\.sh\n\s+fi$")
        self.assertNotIn("continue-on-error", source)
        self.assertNotIn("pull_request_target", source)

    def test_failure_still_uploads_only_local_synthetic_benchmark_evidence(self):
        source = self.workflow()

        upload = source[source.index("- name: Upload synthetic benchmark evidence"):]
        self.assertIn("if: ${{ always() }}", upload)
        self.assertIn("uses: actions/upload-artifact@", upload)
        self.assertRegex(upload, r"(?m)^\s+path: \.local/benchmarks/$")
        self.assertIn("include-hidden-files: true", upload)
        self.assertIn("if-no-files-found: warn", upload)
        self.assertNotRegex(upload.lower(), r"artifact.*pass(?:ed|ing)")
        self.assertNotRegex(source.lower(), r"notari[sz]|codesign|developer id")


if __name__ == "__main__":
    unittest.main()
