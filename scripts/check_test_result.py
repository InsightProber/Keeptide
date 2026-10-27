#!/usr/bin/env python3
"""Reject empty or unreadable XCTest runs, including misspelled selectors."""

import json
from pathlib import Path
import sys


def main() -> int:
    try:
        summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
        counts = [summary[key] for key in ("totalTestCount", "skippedTests", "failedTests")]
        if any(type(count) is not int or count < 0 for count in counts):
            raise ValueError("invalid test counts")
        total, skipped, failed = counts
        if skipped > total or failed > total - skipped:
            raise ValueError("inconsistent test counts")
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print(f"Cannot verify test execution: {error}", file=sys.stderr)
        return 1
    executed = total - skipped
    if executed == 0:
        print("No tests executed. Check the test target/class selector and skipped tests.", file=sys.stderr)
        return 1
    if failed or summary.get("result") != "Passed":
        print("The test result did not pass.", file=sys.stderr)
        return 1
    print(f"Verified {executed} executed tests ({skipped} skipped).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
