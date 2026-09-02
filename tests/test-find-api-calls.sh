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

# --- D5: the summary counters must still count after dropping declare -A ---
src3=$(new_tmpdir)
mkdir -p "$src3/com/example"
cat > "$src3/com/example/Svc.java" <<'JAVA'
package com.example;
interface Svc {
    @GET("/v1/users") Call<String> a();
    @POST("/v1/login") Call<String> b();
}
JAVA
cat > "$src3/com/example/Net.java" <<'JAVA'
package com.example;
class Net {
    void go() { new Request.Builder().url("https://api.example.com").build(); }
}
JAVA

out3=$(bash "$SCRIPT" --all "$src3" 2>&1)
assert_contains "$out3" "Retrofit=2" \
  "D5: summary counts two Retrofit annotations without declare -A"
assert_contains "$out3" "OkHttp=1" \
  "D5: summary counts one OkHttp call without declare -A"

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
