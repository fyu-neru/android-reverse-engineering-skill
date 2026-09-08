#!/usr/bin/env bash
# lookup-name.sh — Query the mapping produced by recover-kotlin-names.sh.
#
# Modes:
#   lookup-name.sh <mapping-dir> <substring>      search by real-FQN substring
#   lookup-name.sh <mapping-dir> -o <obf>         resolve obf -> real
#   lookup-name.sh <mapping-dir> -p <pkg>         list a real package
#   lookup-name.sh <mapping-dir> --grep <regex> <sources-dir>
#       grep decompiled sources and annotate each hit with the real class name

set -euo pipefail

usage() {
  cat <<EOF
Usage: lookup-name.sh <mapping-dir> <query>
       lookup-name.sh <mapping-dir> -o <obf-fqn>
       lookup-name.sh <mapping-dir> -p <real-package-substring>
       lookup-name.sh <mapping-dir> --grep <regex> <sources-dir>

<mapping-dir> is the directory produced by recover-kotlin-names.sh
(must contain mapping.json).
EOF
  exit 0
}

[[ $# -lt 2 ]] && usage
DIR="$1"; shift
[[ ! -f "$DIR/mapping.json" ]] && { echo "no mapping.json in $DIR" >&2; exit 1; }

# Resolve the interpreter through lib/tools.sh rather than invoking a
# bare `python3` — see the matching comment in recover-kotlin-names.sh.
# On Windows the name python3 finds only the Microsoft Store stub.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
. "$SCRIPT_DIR/lib/tools.sh"

if ! PY3_BIN=$(tool_resolve python3); then
  echo "lookup-name.sh: no working Python 3 interpreter found." >&2
  echo "  This script is embedded Python and cannot run without one." >&2
  echo "  Run check-deps.sh to see what was probed and how to install one." >&2
  exit 1
fi

"$PY3_BIN" - "$DIR" "$@" <<'PY'
import json, os, re, sys, subprocess
DIR = sys.argv[1]
args = sys.argv[2:]
MAP = json.load(open(os.path.join(DIR, "mapping.json")))
REV = {}
for o, r in MAP.items():
    REV.setdefault(r, []).append(o)

def search(q):
    ql = q.lower()
    for r in sorted(REV):
        if ql in r.lower():
            print(r)
            for o in sorted(REV[r]):
                print(f"    {o}")

def by_obf(o):
    if o not in MAP:
        print(f"no mapping for {o}", file=sys.stderr); sys.exit(1)
    print(f"{o}  ->  {MAP[o]}")
    sibs = [s for s in REV[MAP[o]] if s != o]
    for s in sorted(sibs):
        print(f"    sibling: {s}")

def by_pkg(p):
    pl = p.lower()
    for r in sorted(REV):
        if pl in r.rsplit(".", 1)[0].lower():
            print(r)
            for o in sorted(REV[r]):
                print(f"    {o}")

def grep_annot(pattern, sources):
    res = subprocess.run(
        ["grep", "-rEn", "--include=*.java", pattern, sources],
        capture_output=True, text=True)
    for line in res.stdout.splitlines():
        try:
            path, lineno, content = line.split(":", 2)
        except ValueError:
            continue
        rel = os.path.relpath(path, sources)
        obf = rel.replace(os.sep, ".")[:-5]
        suffix = f"  // {MAP[obf]}" if obf in MAP else ""
        print(f"{rel}:{lineno}:{content}{suffix}")

if args[0] == "-o" and len(args) == 2:
    by_obf(args[1])
elif args[0] == "-p" and len(args) == 2:
    by_pkg(args[1])
elif args[0] == "--grep" and len(args) == 3:
    grep_annot(args[1], args[2])
else:
    search(" ".join(args))
PY
