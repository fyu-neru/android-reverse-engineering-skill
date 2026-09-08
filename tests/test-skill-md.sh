#!/usr/bin/env bash
# test-skill-md.sh — guards SKILL.md's frontmatter trigger word (Task 8).
#
# The fernflower -> vineflower rename intentionally keeps the literal word
# "fernflower" in exactly one place: the frontmatter `trigger:` line, which
# is a search term users type ("decompile with fernflower") rather than an
# interface contract renamed alongside --engine/env vars/output dirs. A
# later blanket find-and-replace across this file would silently delete
# that one deliberately-kept occurrence and remove a real discovery path;
# this test turns "remember not to sed that line" into something the suite
# enforces, rather than a comment someone has to notice.
#
# Plain-text comparison, not a regex feature, so it fails the same way on
# every platform this suite runs on.
set -uo pipefail

. "$(dirname "$0")/lib/harness.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_MD="$REPO_ROOT/plugins/android-reverse-engineering/skills/android-reverse-engineering/SKILL.md"

content=$(cat "$SKILL_MD" 2>/dev/null || true)
lower_content=$(printf '%s' "$content" | tr '[:upper:]' '[:lower:]')

# Count occurrences of the substring "fernflower", not lines — grep -o
# prints one line per match, so wc -l counts total occurrences even when
# more than one appears on the same line.
occurrence_count=$(printf '%s' "$lower_content" | grep -o 'fernflower' | wc -l | tr -d ' ')
assert_equals "$occurrence_count" "1" \
  "[all] SKILL.md contains the word fernflower (case-insensitive) exactly once"

# The single surviving occurrence must be on the frontmatter's trigger:
# line specifically, not merely somewhere in the file.
trigger_line=$(printf '%s\n' "$content" | grep '^trigger:')
lower_trigger_line=$(printf '%s' "$trigger_line" | tr '[:upper:]' '[:lower:]')
assert_contains "$lower_trigger_line" "fernflower" \
  "[all] SKILL.md's sole fernflower occurrence is on the frontmatter trigger: line"

cleanup_tmpdirs
print_summary
