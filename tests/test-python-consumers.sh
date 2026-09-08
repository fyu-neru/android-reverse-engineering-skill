#!/usr/bin/env bash
# The two scripts that ARE embedded Python — recover-kotlin-names.sh and
# lookup-name.sh — must reach their interpreter through lib/tools.sh's
# resolution layer, not through a bare `python3`.
#
# Why this file exists: check-deps reports `[OK] python3 <version>` based
# on what tool_resolve finds. On Windows that is `python`, because the
# name `python3` resolves only to the Microsoft Store's stub there and
# python.org's installer never provides a python3.exe at all. A consumer
# that invokes a bare `python3` therefore runs the stub and fails on
# precisely the machine check-deps just called OK — the report would be
# describing an interpreter nothing actually uses.
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts"
RECOVER="$SCRIPTS/recover-kotlin-names.sh"
LOOKUP="$SCRIPTS/lookup-name.sh"

# Scrub every name the python3 row probes for, so nothing on the real
# machine can satisfy these runs by accident. Derived from the row, for
# the same reason test-check-deps.sh derives it: a hardcoded list drifts
# away from the row the moment the row is widened.
PLUGIN_ROOT_PC="$REPO_ROOT/plugins/android-reverse-engineering"
TOOLS_SH_PC="$PLUGIN_ROOT_PC/skills/android-reverse-engineering/scripts/lib/tools.sh"
pc_probe_names=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_PC" TOOLS_SH_PATH="$TOOLS_SH_PC" \
  "${BASH:-bash}" -c '. "$TOOLS_SH_PATH"; tool_field python3 probe')

assert_contains "$pc_probe_names" "python3" \
  "[all] precondition: the probe list was read from tools.psv (an empty one would leave the PATH below unscrubbed and every assertion here meaningless)"

pc_oldpath="$PATH"
pc_oldifs="$IFS"
pc_oldopts="$-"
pc_scrub_failed=""
IFS=','
set -f
for pc_name in $pc_probe_names; do
  IFS="$pc_oldifs"
  if [ -n "$pc_name" ] && [ "$pc_name" != "-" ]; then
    # Record a failure rather than swallowing it: path_without_command
    # goes out of its way to fail instead of returning a PATH that
    # quietly lost a directory's tools, and discarding that status here
    # would put the lie straight back.
    if pc_scrubbed=$(path_without_command "$pc_name"); then
      PATH="$pc_scrubbed"
    else
      pc_scrub_failed="$pc_scrub_failed $pc_name"
    fi
  fi
  IFS=','
done
IFS="$pc_oldifs"
case "$pc_oldopts" in *f*) ;; *) set +f ;; esac
path_no_python="$PATH"
PATH="$pc_oldpath"

assert_equals "$pc_scrub_failed" "" \
  "[all] precondition: path_without_command succeeded for every probed name"

# A fixture PATH that still resolves one of those names would mean the
# runs below were satisfied by this machine's own Python rather than by
# the stub they are supposed to be about.
pc_leak=""
pc_oldifs="$IFS"
pc_oldopts="$-"
IFS=','
set -f
for pc_name in $pc_probe_names; do
  IFS="$pc_oldifs"
  if [ -n "$pc_name" ] && [ "$pc_name" != "-" ]; then
    if PATH="$path_no_python" command -v "$pc_name" >/dev/null 2>&1; then
      pc_leak="$pc_leak $pc_name"
    fi
  fi
  IFS=','
done
IFS="$pc_oldifs"
case "$pc_oldopts" in *f*) ;; *) set +f ;; esac
assert_equals "$pc_leak" "" \
  "[all] precondition: the scrubbed PATH resolves none of the names the python3 row probes for"

# A stub that answers the version probe like a real Python 3 and echoes
# its argv for anything else, so a run can be attributed to it. Named
# `python`, never `python3`: that is the whole point — on Windows the
# working interpreter is not called python3, and a consumer that only
# knows that one name never finds it.
pc_bin=$(new_tmpdir)
make_stub_bin "$pc_bin" python3 'exit 49'
make_stub_bin "$pc_bin" python 'case "${1:-}" in
  -c) case "${2:-}" in
        *version_info*) echo "3" ;;
        *python_version*) echo "3.12.10" ;;
        *) echo "3" ;;
      esac
      exit 0 ;;
esac
cat >/dev/null
echo "RESOLVED_PYTHON_RAN: $*"
exit 0'

# --- recover-kotlin-names.sh ---
pc_src=$(new_tmpdir)
mkdir -p "$pc_src/com/example"
cat > "$pc_src/com/example/A.java" <<'JAVA'
@DebugMetadata(c = "com.example.Real", f = "Real.kt")
class a {}
JAVA
pc_out_dir=$(new_tmpdir)

pc_recover_out=$(PATH="$pc_bin:$path_no_python" env -u PYTHON3_BIN \
  "${BASH:-bash}" "$RECOVER" "$pc_src" "$pc_out_dir/mapping" 2>&1)
pc_recover_line=$(printf '%s\n' "$pc_recover_out" | grep '^RESOLVED_PYTHON_RAN:' || true)
if [ -n "$pc_recover_line" ]; then pc_recover_seen=present; else pc_recover_seen=absent; fi
if [ "$pc_recover_seen" = "absent" ]; then
  # Diagnostic, not an assertion: without it a failure here says only
  # "expected present, got absent", which is the least useful thing it
  # could say about a script that did not run.
  echo "  (diagnostic) recover-kotlin-names.sh produced:" >&2
  printf '%s\n' "$pc_recover_out" | sed 's/^/    | /' >&2
  echo "  (diagnostic) PATH head: $(printf '%s' "$pc_bin:$path_no_python" | cut -c1-200)" >&2
  echo "  (diagnostic) python resolves to: $(PATH="$pc_bin:$path_no_python" command -v python 2>/dev/null || echo none)" >&2
fi
assert_equals "$pc_recover_seen" "present" \
  "[all] recover-kotlin-names.sh runs the interpreter tool_resolve found, not a bare python3 (on Windows the name python3 only ever resolves to the Store stub)"

# --- lookup-name.sh ---
pc_map=$(new_tmpdir)
printf '{"a":"com.example.Real"}\n' > "$pc_map/mapping.json"

pc_lookup_out=$(PATH="$pc_bin:$path_no_python" env -u PYTHON3_BIN \
  "${BASH:-bash}" "$LOOKUP" "$pc_map" Real 2>&1)
pc_lookup_line=$(printf '%s\n' "$pc_lookup_out" | grep '^RESOLVED_PYTHON_RAN:' || true)
if [ -n "$pc_lookup_line" ]; then pc_lookup_seen=present; else pc_lookup_seen=absent; fi
assert_equals "$pc_lookup_seen" "present" \
  "[all] lookup-name.sh runs the interpreter tool_resolve found, not a bare python3"

# --- nothing resolves at all: fail with a message that points somewhere ---
pc_stub_only=$(new_tmpdir)
make_stub_bin "$pc_stub_only" python3 'exit 49'

pc_none_out=$(PATH="$pc_stub_only:$path_no_python" env -u PYTHON3_BIN \
  "${BASH:-bash}" "$RECOVER" "$pc_src" "$pc_out_dir/mapping2" 2>&1)
pc_none_status=$?
if [ "$pc_none_status" -ne 0 ]; then pc_none_failed=yes; else pc_none_failed=no; fi
assert_equals "$pc_none_failed" "yes" \
  "[all] recover-kotlin-names.sh exits non-zero when no working interpreter resolves, instead of running a stub and producing an empty mapping"
assert_contains "$pc_none_out" "check-deps" \
  "[all] recover-kotlin-names.sh's no-interpreter message points at check-deps rather than leaving the reader to guess"

cleanup_tmpdirs
print_summary
