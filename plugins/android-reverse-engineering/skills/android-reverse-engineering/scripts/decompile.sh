#!/usr/bin/env bash
# decompile.sh — Decompile APK/XAPK/APKM/APKS/AAB/DEX/ZIP/JAR/AAR/CLASS using jadx, vineflower, or both
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
. "$SCRIPT_DIR/lib/tools.sh"

usage() {
  cat <<EOF
Usage: decompile.sh [OPTIONS] <file>

Decompile an Android package or bytecode archive.

Arguments:
  <file>            Path to a .apk, .xapk, .apkm, .apks, .aab, .dex, .zip,
                    .jar, .aar, or .class file

Options:
  -o, --output DIR  Output directory (default: <filename>-decompiled)
  --deobf           Enable deobfuscation of names
  --no-res          Skip resource decoding (faster, code-only)
  --engine ENGINE   Decompiler engine: jadx, vineflower, or both (default: jadx)
  --mode MODE       jadx decompilation mode: auto, restructure, simple, or
                    fallback. Passed through to jadx as -m. When omitted,
                    nothing is passed and jadx uses its own default (auto).
  -h, --help        Show this help message

Engines:
  jadx        Use jadx (default). Handles APK/XAPK/APKM/APKS/AAB/DEX/ZIP/JAR/AAR
              natively (including split bundles) and decodes resources.
  vineflower  Use Vineflower. Better on complex Java, lambdas, generics.
              Only accepts .jar, .aar, and .class input — it decompiles JVM
              bytecode, not DEX, and dex2jar is no longer part of this pipeline
              (see the design doc for why). Use --engine jadx for anything else.
  both        Run both decompilers side by side for comparison.
              jadx output  → <output>/jadx/
              vineflower   → <output>/vineflower/
              (requires a .jar, .aar, or .class input, same as --engine vineflower)

jadx modes (--mode, jadx-engine only):
  auto         jadx picks the best strategy per method. This is jadx's own
               default — it is never passed explicitly by this script unless
               you type --mode auto yourself.
  restructure  Force the normal CFG-restructuring decompiler.
  simple       A simpler, more literal bytecode-to-source translation.
  fallback     Escape hatch for a class jadx crashes on or decompiles into
               obviously broken output — bypasses the normal decompiler for
               it. Produces less readable code; use only when needed.

Environment:
  VINEFLOWER_JAR   Path to vineflower.jar

Examples:
  decompile.sh app-release.apk
  decompile.sh app-bundle.xapk
  decompile.sh --engine both --deobf library.jar
  decompile.sh --engine vineflower library.jar
EOF
  exit 0
}

# --- Parse arguments ---
OUTPUT_DIR=""
DEOBF=false
NO_RES=false
ENGINE="jadx"
MODE=""
INPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)   OUTPUT_DIR="$2"; shift 2 ;;
    --deobf)       DEOBF=true; shift ;;
    --no-res)      NO_RES=true; shift ;;
    --engine)      ENGINE="$2"; shift 2 ;;
    --mode)        MODE="$2"; shift 2 ;;
    -h|--help)     usage ;;
    -*)            echo "Error: Unknown option $1" >&2; usage ;;
    *)             INPUT_FILE="$1"; shift ;;
  esac
done

# Task 8 (2.0.0) renamed this engine's flag value and env var. Neither
# check below is a compatibility shim — both still refuse to run. They
# only replace a generic "Unknown option"/silent-ignore outcome with a
# message naming the new spelling, so a user hitting either one has
# something to act on.
if [[ -n "${FERNFLOWER_JAR_PATH:-}" ]]; then
  echo "Error: FERNFLOWER_JAR_PATH 已於 2.0.0 更名為 VINEFLOWER_JAR" >&2
  exit 1
fi

# --- Validate input ---
if [[ -z "$INPUT_FILE" ]]; then
  echo "Error: No input file specified." >&2
  usage
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: File not found: $INPUT_FILE" >&2
  exit 1
fi

ext="${INPUT_FILE##*.}"
ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
case "$ext_lower" in
  apk|xapk|apkm|apks|aab|dex|zip|jar|aar|class) ;;
  *)
    echo "Error: Unsupported file type '.$ext'. Expected one of: apk, xapk, apkm, apks, aab, dex, zip, jar, aar, class" >&2
    exit 1
    ;;
esac

case "$ENGINE" in
  jadx|vineflower|both) ;;
  fernflower)
    echo "Error: --engine fernflower 已於 2.0.0 更名為 --engine vineflower" >&2
    exit 1
    ;;
  *)
    echo "Error: Unknown engine '$ENGINE'. Use jadx, vineflower, or both." >&2
    exit 1
    ;;
esac

# Empty MODE is deliberately accepted here (it means --mode was never given):
# run_jadx below only appends -m when MODE is non-empty, so jadx keeps its
# own default rather than this script hardcoding one on jadx's behalf.
case "$MODE" in
  ""|auto|restructure|simple|fallback) ;;
  *)
    echo "Error: Unknown mode '$MODE'. Use auto, restructure, simple, or fallback." >&2
    exit 1
    ;;
esac

BASENAME=$(basename "$INPUT_FILE" ".$ext_lower")
INPUT_FILE_ABS=$(realpath "$INPUT_FILE")

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${BASENAME}-decompiled"
fi

# --- jadx decompilation ---
run_jadx() {
  local out_dir="$1"
  local jadx_status=0
  local count=0

  # Resolved via tool_argv (env override -> PATH probe -> tools.psv
  # candidates), the same resolution order check-deps.sh reports against.
  # A bare `command -v jadx` here would miss a jadx that install-dep.sh
  # just placed at one of tools.psv's candidate paths — exactly the
  # install-then-can't-find-it divergence between check-deps and decompile
  # this resolution layer exists to eliminate.
  if ! tool_argv jadx; then
    echo "Error: jadx is not installed or not in PATH." >&2
    return 1
  fi

  local args=()
  args+=("-d" "$out_dir")
  [[ "$DEOBF" == true ]] && args+=("--deobf")
  [[ "$NO_RES" == true ]] && args+=("--no-res")
  # -m is only appended when --mode was actually given (MODE non-empty).
  # Hardcoding "-m auto" here would silently diverge the moment jadx changes
  # what its own default means — letting jadx decide is the whole point.
  [[ -n "$MODE" ]] && args+=("-m" "$MODE")
  args+=("--show-bad-code")
  args+=("$INPUT_FILE_ABS")

  echo "Running: ${TOOL_ARGV[*]} ${args[*]}"
  if "${TOOL_ARGV[@]}" "${args[@]}"; then
    jadx_status=0
  else
    jadx_status=$?
  fi

  echo "jadx output: $out_dir/sources/"
  if [[ -d "$out_dir/sources" ]]; then
    count=$(find "$out_dir/sources" -name "*.java" | wc -l)
    echo "Java files decompiled by jadx: $count"
  fi

  if [[ $jadx_status -eq 0 ]]; then
    return 0
  fi

  if [[ $count -gt 0 ]]; then
    echo "Warning: jadx exited with status $jadx_status after writing $count Java files; treating this as partial success." >&2
    return 2
  fi

  echo "Error: jadx failed with status $jadx_status and produced no Java output." >&2
  return 1
}

# --- Vineflower decompilation ---
run_vineflower() {
  local out_dir="$1"
  local jar_to_decompile="$INPUT_FILE_ABS"
  local ff_status=0
  local count=0
  local ff_timeout_seconds="${VINEFLOWER_TIMEOUT_SECONDS:-900}"

  # dex2jar has been removed from this pipeline (2.0.0): converting DEX to
  # JVM bytecode first threw away exactly the metadata (lambdas, generic
  # signatures, records, switch-on-string) that made Vineflower worth
  # running in the first place, and jadx reads DEX directly and better. So
  # this engine now only ever runs on real JVM bytecode.
  case "$ext_lower" in
    jar|aar|class) ;;
    *)
      echo "Error: The vineflower engine only decompiles .jar, .aar, and .class files." >&2
      echo "Got '.$ext_lower'. dex2jar conversion has been removed — jadx reads DEX/APK-family files natively and produces better results." >&2
      echo "Use --engine jadx for .apk, .xapk, .apkm, .apks, .aab, .dex, and .zip files." >&2
      return 1
      ;;
  esac

  if ! tool_argv vineflower; then
    echo "Error: Vineflower JAR not found." >&2
    echo "Set VINEFLOWER_JAR or see references/setup-guide.md" >&2
    return 1
  fi

  mkdir -p "$out_dir"

  # Build vineflower args
  local ff_args=()
  ff_args+=("-dgs=1")   # decompile generic signatures
  ff_args+=("-mpm=60")  # 60s max per method to avoid hangs
  if [[ "$DEOBF" == true ]]; then
    ff_args+=("-ren=1")  # rename obfuscated identifiers
  fi
  ff_args+=("$jar_to_decompile")
  ff_args+=("$out_dir")

  echo "Running: ${TOOL_ARGV[*]} ${ff_args[*]}"
  if command -v timeout &>/dev/null && [[ "$ff_timeout_seconds" =~ ^[0-9]+$ ]] && (( ff_timeout_seconds > 0 )); then
    echo "Vineflower timeout: ${ff_timeout_seconds}s (override with VINEFLOWER_TIMEOUT_SECONDS)"
    if timeout "${ff_timeout_seconds}s" "${TOOL_ARGV[@]}" "${ff_args[@]}"; then
      ff_status=0
    else
      ff_status=$?
    fi
  elif "${TOOL_ARGV[@]}" "${ff_args[@]}"; then
    ff_status=0
  else
    ff_status=$?
  fi

  # Vineflower outputs a JAR containing .java files — extract it
  local result_jar="$out_dir/$(basename "$jar_to_decompile")"
  if [[ -f "$result_jar" ]]; then
    local sources_dir="$out_dir/sources"
    mkdir -p "$sources_dir"
    if unzip -qo "$result_jar" -d "$sources_dir"; then
      rm -f "$result_jar"
    else
      echo "Warning: Vineflower result jar $result_jar could not be extracted; checking for direct folder output." >&2
    fi
  fi

  local sources_dir="$out_dir/sources"
  mkdir -p "$sources_dir"
  count=$(find "$sources_dir" -name "*.java" | wc -l)

  # Vineflower may write sources directly into the destination folder tree instead of a result jar.
  if [[ $count -eq 0 ]]; then
    local direct_count=0
    direct_count=$(find "$out_dir" \
      -path "$sources_dir" -prune -o \
      -name "*.java" -type f -print | wc -l)
    if [[ $direct_count -gt 0 ]]; then
      while IFS= read -r -d '' entry; do
        mv "$entry" "$sources_dir"/
      done < <(find "$out_dir" -mindepth 1 -maxdepth 1 \
        ! -name "sources" \
        -print0)
      count=$(find "$sources_dir" -name "*.java" | wc -l)
    fi
  fi

  if [[ $count -gt 0 ]]; then
    echo "Vineflower output: $sources_dir/"
    echo "Java files decompiled by Vineflower: $count"
    if [[ $ff_status -ne 0 ]]; then
      echo "Warning: Vineflower exited with status $ff_status after writing $count Java files; treating this as partial success." >&2
      return 2
    fi
    return 0
  fi

  echo "Error: Vineflower produced no Java output." >&2

  if [[ $ff_status -ne 0 ]]; then
    if [[ $ff_status -eq 124 ]]; then
      echo "Error: Vineflower exceeded timeout (${ff_timeout_seconds}s)." >&2
    fi
    echo "Error: Vineflower exited with status $ff_status." >&2
  fi
  return 1
}

# --- Summary helper ---
print_structure() {
  local src_dir="$1"
  local label="$2"
  if [[ -d "$src_dir" ]]; then
    local packages=()
    echo
    echo "Top-level packages ($label):"
    # BSD find has no -printf; strip the prefix in the shell instead.
    # -mindepth / -maxdepth are portable.
    while IFS= read -r pkg; do
      pkg="${pkg#"$src_dir"/}"
      [[ -n "$pkg" ]] && packages+=("$pkg")
    done < <(find "$src_dir" -mindepth 1 -maxdepth 3 -type d | LC_ALL=C sort)

    local total=${#packages[@]}
    if (( total == 0 )); then
      echo "(none)"
      return
    fi

    # Obfuscated APKs commonly rename every top-level package to a single
    # letter (a/, b/, c/, ...). At maxdepth 3, each of those single-letter
    # roots contributes several nested entries, so a flat positional cap
    # can fill up entirely on obfuscated noise before a real package like
    # com/ — which sorts after two dozen+ single-letter names — is ever
    # reached. List multi-character top-level packages first so a real
    # package name can never be crowded out by single-letter ones, then
    # fill any remaining slots with the single-letter entries.
    local cap=20
    local named=() single=()
    local pkg top
    for pkg in "${packages[@]}"; do
      top="${pkg%%/*}"
      if [[ ${#top} -eq 1 ]]; then
        single+=("$pkg")
      else
        named+=("$pkg")
      fi
    done
    local ordered=(${named[@]+"${named[@]}"} ${single[@]+"${single[@]}"})

    local shown=$cap
    if (( shown > total )); then
      shown=$total
    fi

    local i=0
    while (( i < shown )); do
      echo "${ordered[$i]}"
      ((i += 1))
    done

    if (( total > cap )); then
      echo "... and $((total - cap)) more (showing $cap of $total; single-letter package dirs are listed last)"
    fi
  fi
}

# --- Decompile a single file with the selected engine ---
decompile_single() {
  local file_abs="$1"
  local out_dir="$2"
  local label="$3"

  # Temporarily override INPUT_FILE_ABS for run_jadx/run_vineflower
  local saved_input="$INPUT_FILE_ABS"
  local saved_ext="$ext_lower"
  INPUT_FILE_ABS="$file_abs"
  ext_lower="${file_abs##*.}"
  ext_lower=$(echo "$ext_lower" | tr '[:upper:]' '[:lower:]')

  if [[ -n "$label" ]]; then
    echo "=== Decompiling $label (engine: $ENGINE) ==="
  fi

  case "$ENGINE" in
    jadx)
      local jadx_status=0
      if run_jadx "$out_dir"; then
        jadx_status=0
      else
        jadx_status=$?
      fi
      print_structure "$out_dir/sources" "jadx"
      if [[ $jadx_status -eq 1 ]]; then
        return 1
      fi
      if [[ $jadx_status -eq 2 ]]; then
        echo "jadx completed with warnings but produced usable output."
      fi
      ;;
    vineflower)
      local ff_status=0
      if run_vineflower "$out_dir"; then
        ff_status=0
      else
        ff_status=$?
      fi
      print_structure "$out_dir/sources" "vineflower"
      if [[ $ff_status -eq 1 ]]; then
        return 1
      fi
      if [[ $ff_status -eq 2 ]]; then
        echo "Vineflower completed with warnings but produced usable output."
      fi
      ;;
    both)
      local jadx_status=0
      local ff_status=0
      echo "--- Pass 1: jadx ---"
      if run_jadx "$out_dir/jadx"; then
        jadx_status=0
      else
        jadx_status=$?
      fi
      if [[ $jadx_status -eq 1 ]]; then
        return 1
      fi
      if [[ $jadx_status -eq 2 ]]; then
        echo "Continuing to Vineflower because jadx produced usable output despite warnings."
      fi
      echo
      echo "--- Pass 2: Vineflower ---"
      if run_vineflower "$out_dir/vineflower"; then
        ff_status=0
      else
        ff_status=$?
      fi
      if [[ $ff_status -eq 1 ]]; then
        return 1
      fi
      if [[ $ff_status -eq 2 ]]; then
        echo "Continuing with Vineflower output because it produced usable sources despite warnings."
      fi

      print_structure "$out_dir/jadx/sources" "jadx"
      print_structure "$out_dir/vineflower/sources" "vineflower"

      echo
      echo "=== Comparison ==="
      local jadx_count=0 ff_count=0
      if [[ -d "$out_dir/jadx/sources" ]]; then
        jadx_count=$(find "$out_dir/jadx/sources" -name "*.java" | wc -l)
      fi
      if [[ -d "$out_dir/vineflower/sources" ]]; then
        ff_count=$(find "$out_dir/vineflower/sources" -name "*.java" | wc -l)
      fi
      echo "jadx:        $jadx_count Java files"
      echo "Vineflower:  $ff_count Java files"

      if [[ -d "$out_dir/jadx/sources" ]]; then
        local jadx_error_files
        local jadx_errors
        jadx_error_files=$(grep -rl 'JADX WARNING\|JADX WARN\|JADX ERROR\|Code decompiled incorrectly' "$out_dir/jadx/sources" 2>/dev/null || true)
        if [[ -n "$jadx_error_files" ]]; then
          jadx_errors=$(printf '%s\n' "$jadx_error_files" | wc -l)
        else
          jadx_errors=0
        fi
        echo "jadx files with warnings/errors: $jadx_errors"
      fi
      echo
      echo "Tip: compare specific classes between jadx/ and vineflower/ to pick the better output."
      ;;
  esac

  INPUT_FILE_ABS="$saved_input"
  ext_lower="$saved_ext"
}

# --- Run ---
echo "=== Decompiling $INPUT_FILE (engine: $ENGINE) ==="
echo "Output directory: $OUTPUT_DIR"
echo

# XAPK/APKM/APKS/AAB/DEX/ZIP files are handed to jadx directly (no
# hand-rolled extraction step): jadx natively understands these formats
# (see the design doc's audit of jadx's usage string), extracts and
# decompiles every contained APK/DEX into one merged source tree, and does
# it without the config-split blindness the old per-APK loop here had.
#
# Two capabilities are lost as a result, and are not silently reintroduced:
# jadx does not copy the XAPK's manifest.json into its output, and it does
# not enumerate OBB files. Both are recorded in SKILL.md. The output
# layout also changes: previously each contained APK got its own
# subdirectory under $OUTPUT_DIR; jadx now merges everything into a single
# tree, same as it always has for a plain .apk.
decompile_single "$INPUT_FILE_ABS" "$OUTPUT_DIR" ""

# --- Split/bundled APK detection ---
# Some APKs are bundles: the outer APK contains base.apk + split_config.*.apk
# inside the resources directory. jadx will decompile the thin outer wrapper
# and produce very few Java files. Detect this and re-decompile base.apk.
sources_dir="$OUTPUT_DIR/sources"
resources_dir="$OUTPUT_DIR/resources"
if [[ -d "$sources_dir" && -d "$resources_dir" ]]; then
  java_count=$(find "$sources_dir" -name "*.java" -type f 2>/dev/null | wc -l)
  base_apk=$(find "$resources_dir" -maxdepth 1 -name "base.apk" -type f 2>/dev/null)
  base_apk=${base_apk%%$'\n'*}
  inner_apk_count=$(find "$resources_dir" -maxdepth 1 -name "*.apk" -type f 2>/dev/null | wc -l)

  if [[ "$java_count" -le 10 && -n "$base_apk" ]]; then
    echo
    echo "=== Split/bundled APK detected ==="
    echo "Outer APK produced only $java_count Java file(s) but contains $inner_apk_count inner APK(s):"
    find "$resources_dir" -maxdepth 1 -name "*.apk" -type f -exec basename {} \; | while read -r f; do echo "  - $f"; done
    echo
    echo "Decompiling base.apk (contains the actual app code)..."
    decompile_single "$base_apk" "$OUTPUT_DIR/base" "base.apk"

    # Decompile non-config split APKs
    while IFS= read -r -d '' split_apk; do
      split_name=$(basename "$split_apk" .apk)
      case "$split_name" in
        base|split_config.*) continue ;;
      esac
      echo
      echo "Decompiling $split_name.apk..."
      decompile_single "$split_apk" "$OUTPUT_DIR/$split_name" "$split_name.apk"
    done < <(find "$resources_dir" -maxdepth 1 -name "*.apk" -type f -print0 2>/dev/null)

    # Report skipped config splits
    config_splits=$(find "$resources_dir" -maxdepth 1 -name "split_config.*.apk" -type f 2>/dev/null)
    if [[ -n "$config_splits" ]]; then
      echo
      echo "Skipped config splits (resource/ABI only):"
      echo "$config_splits" | while read -r f; do echo "  - $(basename "$f")"; done
    fi

    echo
    echo "Main decompiled source is in: $OUTPUT_DIR/base/sources/"
  fi
fi

echo
echo "=== Decompilation complete ==="
