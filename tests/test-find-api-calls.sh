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

out=$("${BASH:-bash}" "$SCRIPT" --auth "$src" 2>&1)

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

out2=$("${BASH:-bash}" "$SCRIPT" --auth "$src2" 2>&1)
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

out3=$("${BASH:-bash}" "$SCRIPT" --all "$src3" 2>&1)
assert_contains "$out3" "Retrofit=2" \
  "D5: summary counts two Retrofit annotations using a portable counter"
assert_contains "$out3" "OkHttp=1" \
  "D5: summary counts one OkHttp call using a portable counter"

# extract_section <full-output> <header-text>
# Prints just the body of one "==== <header-text> ====" section (as
# produced by find-api-calls.sh's own section() helper) — the lines
# between that header and the next one. Assertions below use this to
# check the specific first-party/third-party classification list rather
# than the whole run's output, which could contain the same host string
# in an unrelated section for an unrelated reason.
extract_section() {
  printf '%s\n' "$1" | awk -v hdr="==== $2 ====" '
    $0 == hdr { grab=1; next }
    grab && $0 ~ /^====/ { exit }
    grab { print }
  '
}

# --- D9: the denylist regex must escape each hostname's dots before
# joining them with '|', or '.' matches ANY character and a host that
# merely differs from a denylisted one at a dot position gets misclassified
# as third-party. Runs a private copy of the script against a private
# denylist fixture (not the real third_party_hosts.txt, whose entries are
# already hand-escaped) so the unescaped-hostname case can actually be
# exercised: a real denylisted host still matching would pass before AND
# after the fix, so that alone would prove nothing. ---
d9_root=$(new_tmpdir)
mkdir -p "$d9_root/scripts" "$d9_root/references" "$d9_root/src/com/example"
cp "$SCRIPT" "$d9_root/scripts/find-api-calls.sh"
printf 'api.foo.com\n' > "$d9_root/references/third_party_hosts.txt"
cat > "$d9_root/src/com/example/Net.java" <<'JAVA'
package com.example;
class Net {
    void go() {
        String u = "https://apixfoo1com/health";
        String v = "https://api.foo.com/health";
    }
}
JAVA

out_d9=$("${BASH:-bash}" "$d9_root/scripts/find-api-calls.sh" --urls "$d9_root/src" 2>&1)
first_party_d9=$(extract_section "$out_d9" "Likely First-Party Hosts (frequency-sorted)")
third_party_d9=$(extract_section "$out_d9" "Third-Party Hosts (denylist matches, collapsed)")

assert_contains "$first_party_d9" "apixfoo1com" \
  "[all] D9: a host differing from the denylisted 'api.foo.com' only at the dot positions is classified first-party"
assert_not_contains "$third_party_d9" "apixfoo1com" \
  "[all] D9: that same host is NOT misclassified as third-party (would match if '.' were left as ERE 'any char')"
assert_contains "$third_party_d9" "api.foo.com" \
  "[all] D9: the actual denylisted host 'api.foo.com' itself still matches after escaping"

# --- D11: HOSTS_TMP (find-api-calls.sh's second mktemp, used to hold the
# extracted hostname list for --urls) must be cleaned up by the same trap
# that already covers TMP, on a failure path too. Forces the failure
# deterministically: an empty denylist file makes
# `grep -vE '^\s*(#|$)' "$DENYLIST"` select zero lines and exit 1, which
# (under -o pipefail, no `|| true` on that assignment) aborts the
# script right after HOSTS_TMP has been created but before its own
# explicit cleanup runs. Checks the filesystem, not merely the exit code:
# a leaked mktemp file would still leave the run's exit status at 1. ---
d11_root=$(new_tmpdir)
mkdir -p "$d11_root/scripts" "$d11_root/references" "$d11_root/src"
cp "$SCRIPT" "$d11_root/scripts/find-api-calls.sh"
: > "$d11_root/references/third_party_hosts.txt"

d11_tmpdir=$(new_tmpdir)

TMPDIR="$d11_tmpdir" "${BASH:-bash}" "$d11_root/scripts/find-api-calls.sh" --urls "$d11_root/src" \
  >"$d11_root/out.log" 2>&1
status_d11=$?

leftover_d11=$(find "$d11_tmpdir" -type f 2>/dev/null | wc -l | tr -d ' ')

assert_equals "$status_d11" "1" \
  "[all] D11: the empty-denylist failure path exits non-zero (precondition for the residue check below)"
assert_equals "$leftover_d11" "0" \
  "[all] D11: no orphaned mktemp file (HOSTS_TMP) remains in TMPDIR after that failing run"

cleanup_tmpdirs
print_summary
