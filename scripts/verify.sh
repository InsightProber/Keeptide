#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/verify.sh unit CLASS
  ./scripts/verify.sh integration CLASS
  ./scripts/verify.sh ui CLASS
  ./scripts/verify.sh release-build
  ./scripts/verify.sh analyze
  ./scripts/verify.sh all
EOF
}

require_xcode() {
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    selected_developer_dir=$(xcode-select -p 2>/dev/null || true)
    if [ -n "$selected_developer_dir" ]; then
      DEVELOPER_DIR=$selected_developer_dir
      export DEVELOPER_DIR
    fi
  fi

  if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -d "$DEVELOPER_DIR" ]; then
    echo "Full Xcode is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2
    exit 69
  fi

  if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Full Xcode is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer; Command Line Tools alone cannot build Keeptide." >&2
    exit 69
  fi
}

require_class() {
  if [ "$#" -ne 2 ] || [ -z "$2" ]; then
    usage
    exit 64
  fi
}

timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
build_root=".local/build"
derived_data="$build_root/DerivedData"
result_root="$build_root/results"
mkdir -p "$derived_data" "$result_root"

run_xcodebuild() {
  xcodebuild \
    -project Keeptide.xcodeproj \
    -scheme Keeptide \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    "$@"
}

run_test() {
  target=$1
  class_name=$2
  result_bundle="$result_root/${timestamp}-${target}-${class_name}.xcresult"
  run_xcodebuild test \
    -resultBundlePath "$result_bundle" \
    "-only-testing:${target}/${class_name}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=
}

run_all_tests() {
  result_bundle="$result_root/${timestamp}-all-tests.xcresult"
  run_xcodebuild test \
    -resultBundlePath "$result_bundle" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=
}

require_xcode

command_name=${1:-}
case "$command_name" in
  unit|integration)
    require_class "$@"
    run_test KeeptideTests "$2"
    ;;
  ui)
    require_class "$@"
    run_test KeeptideUITests "$2"
    ;;
  release-build)
    [ "$#" -eq 1 ] || { usage; exit 64; }
    run_xcodebuild build -configuration Release CODE_SIGNING_ALLOWED=NO
    ;;
  analyze)
    [ "$#" -eq 1 ] || { usage; exit 64; }
    run_xcodebuild analyze -configuration Debug CODE_SIGNING_ALLOWED=NO
    ;;
  all)
    [ "$#" -eq 1 ] || { usage; exit 64; }
    run_all_tests
    run_xcodebuild build -configuration Release CODE_SIGNING_ALLOWED=NO
    run_xcodebuild analyze -configuration Debug CODE_SIGNING_ALLOWED=NO
    ;;
  *)
    usage
    exit 64
    ;;
esac
