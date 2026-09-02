#!/usr/bin/env bash
# Regression tests for install-dep.sh (Task 5: consumes tools.psv for
# jadx/vineflower; dex2jar and apktool are no longer installable).
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"
SCRIPT="$SCRIPTS_DIR/install-dep.sh"
CHECK_DEPS_SCRIPT="$SCRIPTS_DIR/check-deps.sh"
PLUGIN_ROOT="$REPO_ROOT/plugins/android-reverse-engineering"

# make_curl_stub <bindir> <urllog> <json-body-or-empty> [fail-substring]
# Writes a curl stand-in that distinguishes install-dep.sh's two calling
# shapes: `curl -fsSL -o <dest> <url>` (a download) vs `curl -fsSL <url>`
# (gh_latest_tag's metadata fetch). Every download URL actually requested
# is appended to <urllog>, one per line, so a test can assert on it
# without install-dep.sh ever touching the real network.
#
# An empty <json-body> simulates the GitHub API being unreachable (curl
# exits non-zero) rather than returning a body — this is the offline/
# rate-limited case tool_field's "pin" fallback exists for.
#
# [fail-substring], if given, makes a download URL containing that
# substring fail (exit 22, as real curl -f does on an HTTP error) so a
# test can prove the "try v<pin> then bare <pin>" retry actually retries.
make_curl_stub() {
  local dir="$1" urllog="$2" json="$3" fail="${4:-}"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [ "$2" = "-o" ]; then'
    echo '  dest="$3"; url="$4"'
    echo "  printf '%s\\n' \"\$url\" >> \"$urllog\""
    if [ -n "$fail" ]; then
      echo '  case "$url" in'
      echo "    *$fail*) exit 22 ;;"
      echo '  esac'
    fi
    echo '  touch "$dest"'
    echo '  exit 0'
    echo 'else'
    echo '  url="$2"'
    echo '  case "$url" in'
    echo '    https://api.github.com/*)'
    if [ -n "$json" ]; then
      echo "      cat <<'JSONBODY'"
      printf '%s\n' "$json"
      echo 'JSONBODY'
      echo '      exit 0'
      echo '      ;;'
    else
      echo '      exit 22'
      echo '      ;;'
    fi
    echo '  esac'
    echo '  exit 1'
    echo 'fi'
  } > "$dir/curl"
  chmod +x "$dir/curl"
}

# make_unzip_stub <bindir>
# install_jadx unzips into <install_dir>/bin/{jadx,jadx-gui}; the real
# unzip has nothing valid to extract from a curl-stub-touched empty file,
# so this stand-in materialises the same layout instead.
make_unzip_stub() {
  local dir="$1"
  make_stub_bin "$dir" unzip 'dir=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then dir="$a"; fi
  prev="$a"
done
mkdir -p "$dir/bin"
touch "$dir/bin/jadx" "$dir/bin/jadx-gui"
exit 0'
}

fixture_plugin_root() {
  # <psv-jadx-row-extra-fields> intentionally left to the caller; this just
  # wires up the directory tools.sh's CLAUDE_PLUGIN_ROOT lookup expects
  # (mirrors tests/test-tools-psv.sh's own fixture layout).
  local root lib
  root=$(new_tmpdir)
  lib="$root/skills/android-reverse-engineering/scripts/lib"
  mkdir -p "$lib"
  printf '%s\n' "$root"
}

# =====================================================================
# dex2jar and apktool are no longer installable dependencies (Task 5:
# jadx handles APK/DEX/XAPK/APKM natively, so both moved to
# references/setup-guide.md as manual fallbacks).
# =====================================================================
out=$("${BASH:-bash}" "$SCRIPT" dex2jar 2>&1)
status=$?
assert_equals "$status" "1" \
  "[all] install-dep.sh dex2jar exits non-zero (removed, no longer installable)"
assert_contains "$out" "Unknown dependency 'dex2jar'" \
  "[all] install-dep.sh dex2jar is reported as an unknown dependency"

out=$("${BASH:-bash}" "$SCRIPT" apktool 2>&1)
status=$?
assert_equals "$status" "1" \
  "[all] install-dep.sh apktool exits non-zero (removed, no longer installable)"
assert_contains "$out" "Unknown dependency 'apktool'" \
  "[all] install-dep.sh apktool is reported as an unknown dependency"

usage_out=$("${BASH:-bash}" "$SCRIPT" --help 2>&1)
assert_not_contains "$usage_out" "dex2jar" \
  "[all] install-dep.sh --help no longer lists dex2jar"
assert_not_contains "$usage_out" "apktool" \
  "[all] install-dep.sh --help no longer lists apktool"

# check-deps.sh must not report on tools it can no longer install either —
# Task 3 deliberately kept these checks hardcoded so its own diff stayed
# empty; Task 5 is what removes them.
cd_out=$(PATH="$(new_tmpdir):$PATH" "${BASH:-bash}" "$CHECK_DEPS_SCRIPT" 2>&1)
assert_not_contains "$cd_out" "dex2jar" \
  "[all] check-deps.sh no longer checks for dex2jar"
assert_not_contains "$cd_out" "apktool" \
  "[all] check-deps.sh no longer checks for apktool"

# =====================================================================
# jadx/vineflower "already installed" detection must go through
# tool_resolve (env override -> PATH probe -> candidates), not a
# hardcoded `command -v` check — the same proof shape as check-deps.sh's
# Task 3 test: a hardcoded check cannot see JADX_BIN/FERNFLOWER_JAR_PATH
# at all, so this is only satisfiable by actually consuming the reader.
# =====================================================================
home1=$(new_tmpdir)
emptybin1=$(new_tmpdir)
make_stub_bin "$home1" custom-jadx 'echo "9.9.9"'
jadx_target="$home1/custom-jadx"
# Poison network access: if the env-override resolution regresses to a
# hardcoded `command -v jadx` (which finds nothing here), install_jadx
# would fall through to the real GitHub-release download path instead of
# short-circuiting on "already installed" — hitting the real network
# during a test run. A poisoned curl makes that fallthrough loud and
# immediate instead of slow, flaky, or silently "successful".
make_stub_bin "$emptybin1" curl 'echo "CURL_SHOULD_NOT_RUN" >&2
exit 1'

out1=$(HOME="$home1" PATH="$emptybin1:$PATH" JADX_BIN="$jadx_target" \
       "${BASH:-bash}" "$SCRIPT" jadx 2>&1)
assert_contains "$out1" "[OK]" \
  "[all] install-dep.sh jadx resolves an already-installed jadx via the JADX_BIN env override with nothing on PATH"
assert_contains "$out1" "already installed: 9.9.9" \
  "[all] install-dep.sh jadx reports the JADX_BIN-resolved binary's own version (9.9.9), not a real jadx that may happen to be on this machine's PATH"
assert_not_contains "$out1" "CURL_SHOULD_NOT_RUN" \
  "[all] install-dep.sh jadx does not fall through to the GitHub download path when already resolved"

home2=$(new_tmpdir)
emptybin2=$(new_tmpdir)
make_stub_bin "$emptybin2" curl 'echo "CURL_SHOULD_NOT_RUN" >&2
exit 1'
jar_target="$home2/custom-vineflower.jar"
touch "$jar_target"

out2=$(HOME="$home2" PATH="$emptybin2:$PATH" FERNFLOWER_JAR_PATH="$jar_target" \
       "${BASH:-bash}" "$SCRIPT" vineflower 2>&1)
assert_contains "$out2" "already available: $jar_target" \
  "[all] install-dep.sh vineflower resolves an already-installed jar via the FERNFLOWER_JAR_PATH env override with nothing on PATH"
assert_not_contains "$out2" "CURL_SHOULD_NOT_RUN" \
  "[all] install-dep.sh vineflower does not fall through to the GitHub download path when already resolved"

# =====================================================================
# jadx's GitHub-release install must use gh_repo/asset from tools.psv,
# not a hardcoded "skylot/jadx" / "jadx-<version>.zip" — proven by
# pointing CLAUDE_PLUGIN_ROOT at a fixture tools.psv with different
# values and asserting the actually-requested download URL follows them.
# =====================================================================
fixture_root=$(fixture_plugin_root)
fixture_psv="$fixture_root/skills/android-reverse-engineering/scripts/lib/tools.psv"
cat > "$fixture_psv" <<'PSV'
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
jadx|required|all|path|jadx-test-probe-nonexistent|JADX_BIN_TEST_NONEXISTENT|-|acme/jadx-fake|jadx-fake-{VERSION}.zip|0.0.1|-|test fixture jadx
vineflower|optional|all|jar|vineflower-test-probe-nonexistent,fernflower-test-probe-nonexistent|FERNFLOWER_JAR_PATH_TEST_NONEXISTENT|-|acme/vineflower-fake|vineflower-fake-{VERSION}.jar|0.0.2|-|test fixture vineflower
PSV

home3=$(new_tmpdir)
bin3=$(new_tmpdir)
urllog3="$home3/urls.log"
: > "$urllog3"
json3='{"tag_name": "v2.3.4", "assets": [{"name": "jadx-fake-2.3.4.zip", "digest": "sha256:deadbeef"}]}'
make_curl_stub "$bin3" "$urllog3" "$json3"
make_unzip_stub "$bin3"

out3=$(HOME="$home3" PATH="$bin3:$PATH" CLAUDE_PLUGIN_ROOT="$fixture_root" \
       "${BASH:-bash}" "$SCRIPT" jadx 2>&1)
requested3=$(cat "$urllog3" 2>/dev/null || echo "")
assert_contains "$requested3" "https://github.com/acme/jadx-fake/releases/download/v2.3.4/jadx-fake-2.3.4.zip" \
  "[all] install-dep.sh jadx downloads the gh_repo/asset from tools.psv (fixture repo acme/jadx-fake), not a hardcoded skylot/jadx"
assert_contains "$out3" "jadx 2.3.4 installed" \
  "[all] install-dep.sh jadx install succeeds end-to-end against the tools.psv-driven GitHub release path"

# =====================================================================
# When the GitHub API is unreachable/rate-limited (gh_latest_tag returns
# empty), install-dep.sh must fall back to tools.psv's pinned version
# instead of failing outright — and must try both the "v<pin>" and bare
# "<pin>" tag conventions, since that prefix isn't recorded in tools.psv.
# =====================================================================
home4=$(new_tmpdir)
bin4=$(new_tmpdir)
urllog4="$home4/urls.log"
: > "$urllog4"
# json="" -> simulate the GitHub API being unreachable. fail="v0.0.1" ->
# the first attempt (with the "v" prefix) 404s, forcing the retry onto
# the bare pin version.
make_curl_stub "$bin4" "$urllog4" "" "v0.0.1"
make_unzip_stub "$bin4"

out4=$(HOME="$home4" PATH="$bin4:$PATH" CLAUDE_PLUGIN_ROOT="$fixture_root" \
       "${BASH:-bash}" "$SCRIPT" jadx 2>&1)
requested4=$(cat "$urllog4" 2>/dev/null || echo "")
assert_contains "$out4" "falling back to the pinned version 0.0.1" \
  "[all] install-dep.sh jadx falls back to tools.psv's pinned version when the GitHub API is unreachable"
assert_contains "$requested4" "https://github.com/acme/jadx-fake/releases/download/v0.0.1/jadx-fake-0.0.1.zip" \
  "[all] install-dep.sh jadx's pin fallback tries the v-prefixed tag first"
assert_contains "$requested4" "https://github.com/acme/jadx-fake/releases/download/0.0.1/jadx-fake-0.0.1.zip" \
  "[all] install-dep.sh jadx's pin fallback retries the bare version when the v-prefixed tag 404s"
assert_contains "$out4" "jadx 0.0.1 installed" \
  "[all] install-dep.sh jadx's pin-fallback install still succeeds end-to-end"

cleanup_tmpdirs
echo "SUMMARY $TESTS_RUN $TESTS_FAILED"
