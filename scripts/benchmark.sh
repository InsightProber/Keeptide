#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/benchmark.sh
  ./scripts/benchmark.sh --million

Runs the fixed 10,000-item search oracle and a Release SearchService benchmark.
The default benchmark contains 100,000 items; --million explicitly opts into
the 1,000,000-item stress run. Results are written below .local/benchmarks/.
EOF
}

case "${1:-}" in
  "")
    [ "$#" -eq 0 ] || { usage; exit 64; }
    benchmark_items=100000
    ;;
  --million)
    [ "$#" -eq 1 ] || { usage; exit 64; }
    benchmark_items=1000000
    ;;
  *)
    usage
    exit 64
    ;;
esac

if [ -z "${DEVELOPER_DIR:-}" ]; then
  selected_developer_dir=$(xcode-select -p 2>/dev/null || true)
  if [ -n "$selected_developer_dir" ]; then
    DEVELOPER_DIR=$selected_developer_dir
    export DEVELOPER_DIR
  fi
fi
if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -d "$DEVELOPER_DIR" ] || ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2
  exit 69
fi

worktree_status=$(git status --porcelain --untracked-files=all)
if [ -n "$worktree_status" ]; then
  echo "Benchmark evidence requires a clean worktree so its Git SHA identifies the measured code." >&2
  exit 65
fi

oracle_items=10000
commit_sha=$(git rev-parse HEAD)
short_sha=$(printf '%.12s' "$commit_sha")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_root=${KEEPTIDE_BENCHMARK_OUTPUT_ROOT:-.local/benchmarks}
run_root="$output_root/$timestamp-$short_sha-$benchmark_items"
build_root=${KEEPTIDE_BENCHMARK_BUILD_ROOT:-.local/build}
derived_data="$build_root/benchmark-$timestamp-$short_sha-$benchmark_items"
mkdir -p "$run_root" "$derived_data"

machine="$(uname -m) / $(sysctl -n hw.model) / macOS $(sw_vers -productVersion)"
xcode_version=$(xcodebuild -version | tr '\n' ';' | sed 's/;$//')
swift_version=$(xcrun swiftc --version | sed -n '1p')
toolchain="$xcode_version / $swift_version"

# Xcode strips TEST_RUNNER_ before passing these values to the XCTest process.
export TEST_RUNNER_KEEPTIDE_BENCHMARK_COMMIT_SHA="$commit_sha"
export TEST_RUNNER_KEEPTIDE_BENCHMARK_CONFIGURATION=Release
export TEST_RUNNER_KEEPTIDE_BENCHMARK_MACHINE="$machine"
export TEST_RUNNER_KEEPTIDE_BENCHMARK_TOOLCHAIN="$toolchain"

run_xcodebuild() {
  xcodebuild \
    -project Keeptide.xcodeproj \
    -scheme Keeptide \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    "$@"
}

verify_result() {
  bundle=$1
  summary="$bundle.summary.json"
  xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$summary"
  python3 scripts/check_test_result.py "$summary"
}

oracle_result="$run_root/oracle.xcresult"
oracle_log="$run_root/oracle.log"
export TEST_RUNNER_KEEPTIDE_SEARCH_ORACLE_COUNT="$oracle_items"
run_xcodebuild test \
  -configuration Release \
  -resultBundlePath "$oracle_result" \
  '-only-testing:KeeptideTests/SearchOracleTests' \
  ENABLE_TESTABILITY=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  > "$oracle_log" 2>&1 || { status=$?; cat "$oracle_log"; exit "$status"; }
cat "$oracle_log"
verify_result "$oracle_result"

benchmark_result="$run_root/benchmark.xcresult"
benchmark_log="$run_root/benchmark.log"
export TEST_RUNNER_KEEPTIDE_SEARCH_BENCHMARK_COUNT="$benchmark_items"
run_xcodebuild test \
  -configuration Release \
  -resultBundlePath "$benchmark_result" \
  '-only-testing:KeeptideTests/SearchPerformanceTests' \
  ENABLE_TESTABILITY=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  > "$benchmark_log" 2>&1 || { status=$?; cat "$benchmark_log"; exit "$status"; }
cat "$benchmark_log"
verify_result "$benchmark_result"

python3 scripts/validate_benchmark_report.py \
  --log "$benchmark_log" \
  --output "$run_root/report.json" \
  --expected-sha "$commit_sha" \
  --expected-items "$benchmark_items" \
  --oracle-items "$oracle_items"

echo "Release search benchmark evidence: $run_root/report.json"
