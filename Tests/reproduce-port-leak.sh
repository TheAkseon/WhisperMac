#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/whispermac-port-test.XXXXXX")
clang -framework CoreFoundation "$REPO_DIR/Tests/CFMachPortLifecycle.c" -o "$TEST_DIR/port-lifecycle"
# These processes create only their own Mach ports; no keyboard taps or input.
"$TEST_DIR/port-lifecycle" legacy
"$TEST_DIR/port-lifecycle" invalidate
