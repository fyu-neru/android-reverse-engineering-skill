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

# The curl stub below always materialises a downloaded asset via `touch`
# (an empty file) — this is the sha256 of the empty string, i.e. what
# every stubbed download actually hashes to. Tests that want the accept
# path use this as the "expected" digest; a wrong value proves the reject
# path.
EMPTY_SHA256="sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

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

# gh_json_fixture <tag> <asset_name> <digest>
# Emits a minimal GitHub releases/latest response shaped like the REAL
# API's multi-line pretty-printed JSON (one field per line — verified
# against `gh api repos/skylot/jadx/releases/latest`). gh_asset_digest's
# awk parser is deliberately line-oriented to match that real shape, so a
# fixture that collapses "name" and "digest" onto a single line (a
# same-line JSON object) would silently defeat it — this exists to avoid
# that trap.
gh_json_fixture() {
  local tag="$1" asset_name="$2" digest="$3"
  cat <<EOF
{
  "tag_name": "$tag",
  "assets": [
    {
      "name": "$asset_name",
      "digest": "$digest"
    }
  ]
}
EOF
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
# Task 3 test: a hardcoded check cannot see JADX_BIN/VINEFLOWER_JAR
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

out2=$(HOME="$home2" PATH="$emptybin2:$PATH" VINEFLOWER_JAR="$jar_target" \
       "${BASH:-bash}" "$SCRIPT" vineflower 2>&1)
assert_contains "$out2" "already available: $jar_target" \
  "[all] install-dep.sh vineflower resolves an already-installed jar via the VINEFLOWER_JAR env override with nothing on PATH"
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
cat > "$fixture_psv" <<PSV
id|required|platform|kind|probe|env_override|candidates|gh_repo|asset|pin|pin_digest|purpose
jadx|required|all|path|jadx-test-probe-nonexistent|JADX_BIN_TEST_NONEXISTENT|-|acme/jadx-fake|jadx-fake-{VERSION}.zip|0.0.1|$EMPTY_SHA256|test fixture jadx
vineflower|optional|all|jar|vineflower-test-probe-nonexistent,fernflower-test-probe-nonexistent|VINEFLOWER_JAR_TEST_NONEXISTENT|-|acme/vineflower-fake|vineflower-fake-{VERSION}.jar|0.0.2|$EMPTY_SHA256|test fixture vineflower
PSV

home3=$(new_tmpdir)
bin3=$(new_tmpdir)
urllog3="$home3/urls.log"
: > "$urllog3"
json3=$(gh_json_fixture "v2.3.4" "jadx-fake-2.3.4.zip" "$EMPTY_SHA256")
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

# =====================================================================
# Task 6: digest verification. gh_latest_tag's response already carries
# each asset's "digest"; a mismatch must refuse to install (exit non-zero,
# naming the tool and BOTH digests), and that must stay clearly distinct
# from a genuine network failure (which keeps exiting 2 with the same
# actionable message it always has, not a digest-shaped one).
# =====================================================================

# --- Accept path: test3 above already downloaded and installed jadx
# against a digest ($EMPTY_SHA256) that matches the stub's actual output —
# strengthen it here with an explicit assertion on the verification
# message itself, not just the final "installed" line.
assert_contains "$out3" "jadx digest verified ($EMPTY_SHA256)" \
  "[all] install-dep.sh jadx accepts a download whose sha256 matches the digest from GitHub's release metadata"

# --- Reject path: a digest that does NOT match the downloaded bytes must
# refuse to install, exit non-zero, and name the tool plus both digests —
# never a silent install, never just a generic failure. ---
home5=$(new_tmpdir)
bin5=$(new_tmpdir)
urllog5="$home5/urls.log"
: > "$urllog5"
wrong_digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"
json5=$(gh_json_fixture "v2.3.4" "jadx-fake-2.3.4.zip" "$wrong_digest")
make_curl_stub "$bin5" "$urllog5" "$json5"
make_unzip_stub "$bin5"

out5=$(HOME="$home5" PATH="$bin5:$PATH" CLAUDE_PLUGIN_ROOT="$fixture_root" \
       "${BASH:-bash}" "$SCRIPT" jadx 2>&1)
status5=$?
assert_equals "$status5" "1" \
  "[all] install-dep.sh jadx exits 1 (not 0, not 2) on a digest mismatch — a distinct outcome from both success and a network failure"
assert_contains "$out5" "Digest mismatch for jadx" \
  "[all] install-dep.sh jadx's digest-mismatch refusal names the tool"
assert_contains "$out5" "expected $wrong_digest" \
  "[all] install-dep.sh jadx's digest-mismatch refusal names the expected digest"
assert_contains "$out5" "got $EMPTY_SHA256" \
  "[all] install-dep.sh jadx's digest-mismatch refusal names the actual digest it computed"
assert_not_contains "$out5" "installed to" \
  "[all] install-dep.sh jadx does not install a download that failed digest verification"

# --- Network failure stays distinct from a digest mismatch: when the API
# is unreachable AND the release asset itself cannot be downloaded either
# (a genuine outage, not just a rate-limited metadata endpoint), the
# outcome must be the same exit-2/[MANUAL] behaviour install-dep.sh always
# had — never exit 1, never a "Digest mismatch" message put in front of a
# user who has a connectivity problem, not a tampered file. ---
home6=$(new_tmpdir)
bin6=$(new_tmpdir)
urllog6="$home6/urls.log"
: > "$urllog6"
# json="" -> the API itself is unreachable. fail="https" matches every
# possible download URL (they all start with https://), simulating a
# total outage rather than a merely-rate-limited API.
make_curl_stub "$bin6" "$urllog6" "" "https"

out6=$(HOME="$home6" PATH="$bin6:$PATH" CLAUDE_PLUGIN_ROOT="$fixture_root" \
       "${BASH:-bash}" "$SCRIPT" jadx 2>&1)
status6=$?
assert_equals "$status6" "2" \
  "[all] install-dep.sh jadx exits 2 on a genuine network failure (API and release assets both unreachable) — distinct from the digest-mismatch exit 1"
assert_contains "$out6" "[MANUAL]" \
  "[all] install-dep.sh jadx's network-failure path still prints the actionable [MANUAL] message it always has"
assert_not_contains "$out6" "Digest mismatch" \
  "[all] install-dep.sh jadx's network failure is never reported as a digest mismatch"

# =====================================================================
# Task 8: 'fernflower' is a renamed dependency name, not one install-dep.sh
# still accepts as an alias for 'vineflower'. It must print a migration
# message the user can act on and refuse to run, matching the same
# not-a-compatibility-shim treatment decompile.sh's --engine gives it.
# =====================================================================
out_ff=$("${BASH:-bash}" "$SCRIPT" fernflower 2>&1)
status_ff=$?
assert_equals "$status_ff" "1" \
  "[all] install-dep.sh fernflower (as a dependency name) exits non-zero (renamed to vineflower in 2.0.0)"
assert_contains "$out_ff" "'fernflower'" \
  "[all] install-dep.sh fernflower's migration message names the old dependency name"
assert_contains "$out_ff" "'vineflower'" \
  "[all] install-dep.sh fernflower's migration message names the new dependency name to use instead"

# =====================================================================
# Task 8: install-dep.sh must warn when the user's shell profile still
# exports the pre-2.0.0 FERNFLOWER_JAR_PATH name. Nothing reads it after
# the rename, and add_to_profile is about to append a second, live
# VINEFLOWER_JAR line right next to that now-dead one — silently leaving
# both in place would be confusing for anyone who later greps their
# profile wondering which one is real.
# =====================================================================
home7=$(new_tmpdir)
bin7=$(new_tmpdir)
cat > "$home7/.bashrc" <<'PROFILE'
# pre-existing content from an earlier install
export FERNFLOWER_JAR_PATH="/old/path/to/fernflower.jar"
PROFILE

urllog7="$home7/urls.log"
: > "$urllog7"
json7=$(gh_json_fixture "1.12.0" "vineflower-1.12.0.jar" "$EMPTY_SHA256")
make_curl_stub "$bin7" "$urllog7" "$json7"

out7=$(HOME="$home7" PATH="$bin7:$PATH" "${BASH:-bash}" "$SCRIPT" vineflower 2>&1)

assert_contains "$out7" "$home7/.bashrc still exports FERNFLOWER_JAR_PATH" \
  "[all] install-dep.sh vineflower warns when the profile still exports the old FERNFLOWER_JAR_PATH name"
# Extract just the stale-profile warning line itself, not the whole run's
# output: $out7 ALSO contains an unrelated "VINEFLOWER_JAR set to ..." line
# from the normal install-success path further down, which would make this
# assertion pass even if the warning text itself never mentioned
# VINEFLOWER_JAR at all — exactly the vacuous shape this test used to have
# (it matched the whole run's output and would have passed identically
# before and after the warning text itself was fixed to name the new
# variable).
warning_line7=$(printf '%s\n' "$out7" | grep 'still exports FERNFLOWER_JAR_PATH' || true)
assert_contains "$warning_line7" "VINEFLOWER_JAR" \
  "[all] install-dep.sh vineflower's profile warning line itself names the new VINEFLOWER_JAR variable to migrate to"

cleanup_tmpdirs
print_summary
