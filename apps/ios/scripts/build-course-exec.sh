#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$IOS_DIR/Support/learnfold-course-exec.c"
OUTPUT="$IOS_DIR/Resources/learnfold-course-exec"
MODE="${1:-build}"
REQUIRED_ZIG_VERSION="0.15.2"

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig is required to reproducibly build learnfold-course-exec" >&2
  exit 1
fi
ACTUAL_ZIG_VERSION="$(zig version)"
if [[ "$ACTUAL_ZIG_VERSION" != "$REQUIRED_ZIG_VERSION" ]]; then
  echo "error: learnfold-course-exec requires zig $REQUIRED_ZIG_VERSION (found $ACTUAL_ZIG_VERSION)" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
BUILT="$TEMP_DIR/learnfold-course-exec"

zig cc \
  -target aarch64-linux-musl \
  -static \
  -Os \
  -s \
  "$SOURCE" \
  -o "$BUILT"

case "$MODE" in
  build)
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$BUILT" "$OUTPUT"
    chmod 0755 "$OUTPUT"
    shasum -a 256 "$OUTPUT"
    ;;
  --check|check)
    if ! cmp -s "$BUILT" "$OUTPUT"; then
      echo "error: bundled learnfold-course-exec does not match its checked-in C source" >&2
      echo "run: apps/ios/scripts/build-course-exec.sh" >&2
      exit 1
    fi
    shasum -a 256 "$OUTPUT"
    ;;
  *)
    echo "usage: $0 [build|--check]" >&2
    exit 2
    ;;
esac
