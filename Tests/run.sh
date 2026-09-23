#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/whispermac-tests.XXXXXX")
swiftc -O -framework Cocoa -module-cache-path "$TEST_DIR/module-cache" \
    "$REPO_DIR/Sources/KeyboardMonitor.swift" "$REPO_DIR/Tests/main.swift" \
    -o "$TEST_DIR/keyboard-tests"
"$TEST_DIR/keyboard-tests"
