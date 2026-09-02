#!/usr/bin/env bash
# Regression tests for find-api-calls.sh
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/find-api-calls.sh"

# --- D1: --auth must actually search, not silently drop the regex ---
src=$(new_tmpdir)
mkdir -p "$src/com/example"
cat > "$src/com/example/Api.java" <<'JAVA'
package com.example;
class Api {
    static final String API_KEY = "api_key=SECRET123";
    static final String BASE_URL = "https://api.example.com";
}
JAVA

out=$(bash "$SCRIPT" --auth "$src" 2>&1)

assert_contains "$out" "SECRET123" \
  "D1: --auth finds a plaintext api_key in the sources"
assert_contains "$out" "BASE_URL" \
  "D1: --auth finds base URL constants"

# Case-insensitivity must survive the fix: the -i flag has to reach grep.
src2=$(new_tmpdir)
mkdir -p "$src2/com/example"
cat > "$src2/com/example/Upper.java" <<'JAVA'
package com.example;
class Upper { static final String X = "API_KEY=UPPERCASE456"; }
JAVA

out2=$(bash "$SCRIPT" --auth "$src2" 2>&1)
assert_contains "$out2" "UPPERCASE456" \
  "D1: --auth is still case-insensitive after the fix"

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
