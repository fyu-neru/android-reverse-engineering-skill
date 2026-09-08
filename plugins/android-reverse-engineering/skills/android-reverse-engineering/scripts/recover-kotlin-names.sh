#!/usr/bin/env bash
# recover-kotlin-names.sh — Rebuild a (obfuscated -> real) class-name map
# from Kotlin metadata strings left in decompiled sources.
#
# R8 obfuscates JVM symbols but cannot strip the Kotlin metadata strings —
# the Kotlin runtime (reflection, coroutines) needs them at runtime. Two
# annotations carry the original FQN:
#
#   * @DebugMetadata(c = "<full.qualified.Name>", f = "<File.kt>", ...)
#     emitted for almost every `suspend` function (every coroutine
#     SuspendLambda).
#
#   * @Metadata(... d2 = {"...L<pkg/Class>;..."} ...) listing internal
#     class refs of the file.
#
# Typical recovery on a real-world app: 30-50 % of classes regain their real
# names — usually 100 % of the *Repository / *ViewModel / *UseCase / *Impl
# classes you actually want to read.

set -euo pipefail

usage() {
  cat <<EOF
Usage: recover-kotlin-names.sh <decompiled-sources-dir> [output-dir]

Walks every *.java under <decompiled-sources-dir>, mines @DebugMetadata
and @Metadata annotations, and writes:

  <output-dir>/mapping.tsv   tab-separated  obf_fqn <TAB> real_fqn <TAB> file
  <output-dir>/mapping.json  same data as JSON  { obf_fqn: real_fqn, ... }
  <output-dir>/by_package/   one file per real package, listing
                             real_fqn <TAB> obf_fqn <TAB> file

If [output-dir] is omitted, files are written next to the sources dir.
EOF
  exit 0
}

[[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]] && usage
SRC="$1"
OUT="${2:-$(dirname "$SRC")/mapping}"
[[ ! -d "$SRC" ]] && { echo "not a directory: $SRC" >&2; exit 1; }

mkdir -p "$OUT/by_package"

# Resolve the interpreter through lib/tools.sh instead of invoking a bare
# `python3`. On Windows that name resolves only to the Microsoft Store's
# app-execution stub — a real file that runs and exits 49 — because
# python.org's installer provides `python` and never a python3.exe. A
# bare call therefore runs the stub and fails on exactly the machine
# check-deps.sh has just reported `[OK] python3` for, which would make
# that report describe an interpreter nothing here actually uses.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
. "$SCRIPT_DIR/lib/tools.sh"

if ! PY3_BIN=$(tool_resolve python3); then
  echo "recover-kotlin-names.sh: no working Python 3 interpreter found." >&2
  echo "  This script is embedded Python and cannot run without one." >&2
  echo "  Run check-deps.sh to see what was probed and how to install one." >&2
  exit 1
fi

"$PY3_BIN" - "$SRC" "$OUT" <<'PY'
import os, re, sys, json
from collections import defaultdict

SRC, OUT = sys.argv[1], sys.argv[2]

# @DebugMetadata(c = "com.foo.Bar$Inner$1", ...)
RE_DEBUG = re.compile(r'@DebugMetadata\([^)]*?c\s*=\s*"([^"]+)"', re.S)
# @Metadata(... d2 = { "...Lcom/foo/Bar;..." ...} )
RE_DTWO  = re.compile(r'@Metadata\([^)]*?d2\s*=\s*\{([^}]*)\}', re.S)
RE_LCLASS = re.compile(r'L([A-Za-z][\w/$]+);')
# jadx sometimes emits this comment for renamed classes
RE_RENAMED = re.compile(r'/\*\s*renamed from:\s*([\w.$]+)\s*\*/')

# Skip third-party / framework trees — their names are already real.
SKIP_PREFIXES = (
    "kotlin.", "kotlinx.", "androidx.", "android.", "java.", "javax.",
    "com.google.", "com.facebook.", "com.appsflyer.", "com.datadog.",
    "io.ktor.", "io.sentry.", "io.realm.", "okhttp3.", "okio.",
    "com.squareup.", "com.bumptech.", "com.airbnb.", "com.payu.",
    "com.storyteller.", "zendesk.", "io.intercom.", "com.microsoft.",
    "com.tinder.", "com.hotjar.", "com.amplitude.", "com.segment.",
    "com.mixpanel.", "com.onesignal.", "com.stripe.", "com.braintreepayments.",
    "retrofit2.", "dagger.", "javax.inject.", "org.jetbrains.",
)

mapping = {}
file_real = {}
counts = defaultdict(int)

for dp, _, files in os.walk(SRC):
    for f in files:
        if not f.endswith(".java"):
            continue
        path = os.path.join(dp, f)
        rel = os.path.relpath(path, SRC)
        obf = rel[:-5].replace(os.sep, ".")
        if obf.startswith(SKIP_PREFIXES):
            continue
        try:
            text = open(path, "r", errors="replace").read()
        except OSError:
            continue
        real = None

        m = RE_DEBUG.search(text)
        if m:
            real = m.group(1).split("$", 1)[0]
            counts["debug_meta"] += 1

        if not real:
            m = RE_DTWO.search(text)
            if m:
                for lm in RE_LCLASS.finditer(m.group(1)):
                    cand = lm.group(1).replace("/", ".").split("$", 1)[0]
                    if "." in cand and not cand.startswith(("kotlin.", "java.", "android")):
                        real = cand
                        counts["d2"] += 1
                        break

        if not real:
            m = RE_RENAMED.search(text)
            if m:
                real = m.group(1)
                counts["renamed"] += 1

        if real:
            mapping[obf] = real
            file_real[obf] = path

with open(os.path.join(OUT, "mapping.tsv"), "w") as f:
    f.write("obf_fqn\treal_fqn\tfile\n")
    for k in sorted(mapping):
        f.write(f"{k}\t{mapping[k]}\t{file_real[k]}\n")

with open(os.path.join(OUT, "mapping.json"), "w") as f:
    json.dump(mapping, f, indent=2, sort_keys=True)

by_pkg = defaultdict(list)
for obf, real in mapping.items():
    pkg = real.rsplit(".", 1)[0] if "." in real else "(default)"
    by_pkg[pkg].append((real, obf, file_real[obf]))

for pkg, rows in by_pkg.items():
    safe = os.path.basename(pkg).replace(".", "_") or "default"
    with open(os.path.join(OUT, "by_package", f"{safe}.txt"), "w") as f:
        for real, obf, p in sorted(rows):
            f.write(f"{real}\t{obf}\t{p}\n")

print(f"Recovered {len(mapping)} class names")
for k, v in counts.items():
    print(f"  via {k}: {v}")
print(f"Real packages: {len(by_pkg)}")
print(f"Wrote {OUT}/mapping.tsv, mapping.json, by_package/")
PY
