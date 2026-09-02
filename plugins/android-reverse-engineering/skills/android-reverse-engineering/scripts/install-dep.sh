#!/usr/bin/env bash
# install-dep.sh — Install a single dependency for Android reverse engineering
# Usage: install-dep.sh <dependency>
# Dependencies: java, jadx, vineflower, adb
#
# jadx and vineflower resolve their candidate paths, GitHub repo, release
# asset filename and pinned fallback version from lib/tools.psv (via
# lib/tools.sh) rather than hardcoding them here — see lib/tools.sh's
# header comment. dex2jar and apktool are no longer installable by this
# script (2.0.0): jadx handles APK/DEX/XAPK/APKM natively, so both are now
# manual-fallback tools documented in references/setup-guide.md instead of
# dependencies with an install path.
#
# Exit codes:
#   0 — installed successfully
#   1 — installation failed (including a digest mismatch on a downloaded
#       release asset — refused, not installed)
#   2 — requires manual action (e.g. sudo needed but not available, or the
#       GitHub API and its release assets are both unreachable)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tools.sh
. "$SCRIPT_DIR/lib/tools.sh"

usage() {
  cat <<EOF
Usage: install-dep.sh <dependency>

Install a dependency required for Android reverse engineering.

Available dependencies:
  java         Java JDK 17+
  jadx         jadx decompiler
  vineflower   Vineflower (Fernflower fork) decompiler
  adb          Android Debug Bridge

The script detects your OS and package manager, then:
  - Installs directly if possible (brew, or user-local install)
  - Uses sudo if available and needed
  - Prints manual instructions if neither option works
EOF
  exit 0
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

DEP="$1"

# --- Detect environment ---
OS="unknown"
PKG_MANAGER="none"
HAS_SUDO=false
ARCH=$(uname -m)

case "$(uname -s)" in
  Linux)  OS="linux" ;;
  Darwin) OS="macos" ;;
esac

# Detect package manager
if command -v brew &>/dev/null; then
  PKG_MANAGER="brew"
elif command -v apt-get &>/dev/null; then
  PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
  PKG_MANAGER="dnf"
elif command -v pacman &>/dev/null; then
  PKG_MANAGER="pacman"
fi

# Check sudo availability
if command -v sudo &>/dev/null; then
  if sudo -n true 2>/dev/null; then
    HAS_SUDO=true
  else
    # sudo exists but may need password — we'll try it and let it prompt
    HAS_SUDO=true
  fi
fi

info()  { echo "[INFO] $*"; }
ok()    { echo "[OK] $*"; }
fail()  { echo "[FAIL] $*" >&2; }
manual() {
  echo "[MANUAL] $*" >&2
  echo "         Cannot install automatically. Please install manually and retry." >&2
  exit 2
}

# --- Helper: install via system package manager (needs sudo on Linux) ---
pkg_install() {
  local pkg="$1"
  case "$PKG_MANAGER" in
    brew)
      info "Installing $pkg via Homebrew..."
      brew install "$pkg"
      ;;
    apt)
      if [[ "$HAS_SUDO" == true ]]; then
        info "Installing $pkg via apt..."
        sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg"
      else
        manual "Run: sudo apt-get install $pkg"
      fi
      ;;
    dnf)
      if [[ "$HAS_SUDO" == true ]]; then
        info "Installing $pkg via dnf..."
        sudo dnf install -y "$pkg"
      else
        manual "Run: sudo dnf install $pkg"
      fi
      ;;
    pacman)
      if [[ "$HAS_SUDO" == true ]]; then
        info "Installing $pkg via pacman..."
        sudo pacman -S --noconfirm "$pkg"
      else
        manual "Run: sudo pacman -S $pkg"
      fi
      ;;
    *)
      manual "No supported package manager found. Install $pkg manually."
      ;;
  esac
}

# --- Helper: download a file ---
download() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL -o "$dest" "$url"
  elif command -v wget &>/dev/null; then
    wget -q -O "$dest" "$url"
  else
    fail "Neither curl nor wget available."
    return 1
  fi
}

# --- Helper: get latest GitHub release tag AND the target asset's digest,
# from the SAME API response (no second round-trip, no TOCTOU window where
# the tag and the asset digest could come from two different releases).
#
# Sets GH_TAG (empty if the API is unreachable — the network-failure case
# gh_release_download's pin fallback exists for) and GH_BODY (the raw JSON,
# for gh_asset_digest to read afterward). Must be called directly, not via
# command substitution ($(...)) — see gh_release_download's comment below
# for why a subshell would silently discard both globals.
GH_TAG=""
GH_BODY=""
gh_latest_tag() {
  local repo="$1"
  local url="https://api.github.com/repos/$repo/releases/latest"
  GH_TAG=""
  GH_BODY=""
  if command -v curl &>/dev/null; then
    GH_BODY=$(curl -fsSL "$url" 2>/dev/null) || GH_BODY=""
  elif command -v wget &>/dev/null; then
    GH_BODY=$(wget -q -O - "$url" 2>/dev/null) || GH_BODY=""
  fi
  # <<< here-string, not a pipe: `head` is nowhere near this, so pipefail's
  # SIGPIPE race (the reason `head` never appears after a pipe anywhere in
  # this file) does not apply.
  GH_TAG=$(sed -n '/"tag_name"/{s/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p;q;}' <<<"$GH_BODY")
}

# gh_asset_digest <asset_name>
# Extracts the "digest" field of <asset_name> from GH_BODY (set by the most
# recent gh_latest_tag call) — the SAME response gh_latest_tag already
# fetched. Prints nothing if the asset isn't present in that response.
# awk, not a pipe into `head`: it consumes its whole input rather than
# exiting early, so it cannot trigger the SIGPIPE race `head` can.
gh_asset_digest() {
  local asset_name="$1"
  awk -v want="\"name\": \"$asset_name\"" '
    index($0, want) > 0 { infield = 1; next }
    infield && index($0, "\"name\":") > 0 { infield = 0 }
    infield && index($0, "\"digest\":") > 0 {
      line = $0
      sub(/^[^"]*"digest": *"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' <<<"$GH_BODY"
}

# --- Helper: sha256 a file without depending on a GNU-only tool ---
sha256_of() {
  local f="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    return 1
  fi
}

# verify_digest <tool> <file> <expected-sha256:hex>
# Refuses on any mismatch (or on being unable to compute a digest at all) —
# it never falls through to "probably fine". Never call this with an empty
# <expected>; the caller must decide what "nothing to verify against"
# means (gh_release_download below treats it as a manual-action case, not
# as an implicit pass).
verify_digest() {
  local tool="$1" file="$2" expected="$3" actual
  actual=$(sha256_of "$file") || {
    fail "Could not compute a checksum for $tool (neither sha256sum nor shasum is available)."
    return 1
  }
  actual="sha256:$actual"
  if [[ "$actual" != "$expected" ]]; then
    fail "Digest mismatch for $tool: expected $expected, got $actual. Refusing to install a possibly corrupted, truncated, swapped, or tampered download."
    return 1
  fi
  ok "$tool digest verified ($expected)"
  return 0
}

# --- Helper: download a tools.psv-listed tool's GitHub release asset ---
# gh_release_download <id> <suffix>
# Resolves gh_repo/asset/pin/pin_digest for <id> from tools.psv, tries the
# live latest tag first, and falls back to the pinned version when the
# GitHub API is unreachable or rate-limited (gh_latest_tag leaves GH_TAG
# empty). Downloads the resolved asset into a fresh temp file (named with
# <suffix>, e.g. ".zip"), verifies its digest, and — only once that passes
# — leaves that file's path in GH_DL_FILE and the resolved version in
# GH_DL_VERSION. bash 3.2 has no namerefs, and this function must NOT be
# called via command substitution ($(...)), which would fork a subshell
# and silently discard every one of those globals before the caller could
# read them. Call it directly and check its exit status instead.
#
# Three distinct outcomes, deliberately not collapsed into one:
#   - return 1: the download itself failed (a genuine network failure —
#     the API and/or the release asset were unreachable). The caller's
#     existing fail+manual (exit 2) handling is untouched by this task.
#   - exit 1 (from here, directly): the download succeeded but its digest
#     did not match — refused, not installed, naming the tool and both
#     digests. This must never be confused with the network-failure case
#     above, so it does not go through "return 1" at all.
#   - return 0: verified and safe to install.
GH_DL_FILE=""
GH_DL_VERSION=""
gh_release_download() {
  local id="$1" suffix="$2"
  local repo asset_tmpl pin pin_digest tag version asset_name url tmp t expected_digest
  GH_DL_FILE=""
  GH_DL_VERSION=""
  repo=$(tool_field "$id" gh_repo) || return 1
  asset_tmpl=$(tool_field "$id" asset) || return 1
  pin=$(tool_field "$id" pin) || return 1
  pin_digest=$(tool_field "$id" pin_digest) || return 1

  gh_latest_tag "$repo"
  tag="$GH_TAG"
  tmp=$(mktemp "/tmp/${id}-XXXXXX${suffix}")

  if [[ -n "$tag" ]]; then
    version="${tag#v}"
    asset_name="${asset_tmpl//\{VERSION\}/$version}"
    expected_digest=$(gh_asset_digest "$asset_name")
    info "Downloading $id $version..."
    url="https://github.com/$repo/releases/download/${tag}/${asset_name}"
    if ! download "$url" "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    if [[ -z "$expected_digest" ]]; then
      rm -f "$tmp"
      fail "GitHub's release metadata for $asset_name did not include a digest to verify against."
      manual "Download and verify manually from https://github.com/$repo/releases/tag/$tag"
    fi
  else
    info "Could not reach the GitHub API for $repo (unreachable or rate-limited); falling back to the pinned version $pin."
    version="$pin"
    expected_digest="$pin_digest"
    asset_name="${asset_tmpl//\{VERSION\}/$version}"
    info "Downloading $id $version..."
    # The pinned version's tag prefix isn't recorded in tools.psv (jadx
    # tags "v1.5.6", Vineflower tags "1.12.0" — real per-project data, not
    # an installation strategy, and not worth a column for two data
    # points used nowhere else): try both conventions, the same way
    # dex2jar's pre-existing alternate-naming retry already did.
    tag=""
    for t in "v$version" "$version"; do
      url="https://github.com/$repo/releases/download/${t}/${asset_name}"
      if download "$url" "$tmp" 2>/dev/null; then
        tag="$t"
        break
      fi
    done
    if [[ -z "$tag" ]]; then
      # Both tag conventions failed to download — a genuine network
      # failure (the API AND the release assets are unreachable), not a
      # digest problem. Stays a plain `return 1` so the caller's existing
      # fail+manual/exit-2 path handles it exactly as before this task.
      rm -f "$tmp"
      return 1
    fi
  fi

  if ! verify_digest "$id" "$tmp" "$expected_digest"; then
    rm -f "$tmp"
    exit 1
  fi

  GH_DL_FILE="$tmp"
  GH_DL_VERSION="$version"
  return 0
}

# --- Helper: add a line to shell profile if not already present ---
add_to_profile() {
  local line="$1"
  local profile=""
  if [[ -f "$HOME/.zshrc" ]]; then
    profile="$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then
    profile="$HOME/.bashrc"
  elif [[ -f "$HOME/.profile" ]]; then
    profile="$HOME/.profile"
  fi

  if [[ -n "$profile" ]]; then
    if ! grep -qF "$line" "$profile" 2>/dev/null; then
      echo "$line" >> "$profile"
      info "Added to $profile: $line"
      info "Run 'source $profile' or start a new shell to apply."
    fi
  else
    info "Add this to your shell profile: $line"
  fi
}

# =====================================================================
# Dependency installers
# =====================================================================

install_java() {
  if command -v java &>/dev/null; then
    local ver
    ver=$(java -version 2>&1)
    ver=${ver%%$'\n'*}
    ver=$(echo "$ver" | sed -n 's/.*"\([0-9]*\)\..*/\1/p')
    if [[ -n "$ver" ]] && (( ver >= 17 )); then
      ok "Java $ver already installed"
      return 0
    fi
  fi

  info "Installing Java JDK 17+..."
  case "$PKG_MANAGER" in
    brew)    brew install openjdk@17 ;;
    apt)     pkg_install "openjdk-17-jdk" ;;
    dnf)     pkg_install "java-17-openjdk-devel" ;;
    pacman)  pkg_install "jdk17-openjdk" ;;
    *)       manual "Install Java JDK 17+ from https://adoptium.net/" ;;
  esac

  # Verify
  if command -v java &>/dev/null; then
    local installed_ver_line
    installed_ver_line=$(java -version 2>&1)
    installed_ver_line=${installed_ver_line%%$'\n'*}
    ok "Java installed: $installed_ver_line"
  else
    fail "Java installation may require PATH update."
    if [[ "$PKG_MANAGER" == "brew" ]]; then
      add_to_profile 'export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"'
    fi
    exit 1
  fi
}

install_jadx() {
  local resolved
  if resolved=$(tool_resolve jadx); then
    ok "jadx already installed: $("$resolved" --version 2>/dev/null || echo 'unknown')"
    return 0
  fi

  # Try brew first (cleanest)
  if [[ "$PKG_MANAGER" == "brew" ]]; then
    info "Installing jadx via Homebrew..."
    brew install jadx
    ok "jadx installed via Homebrew"
    return 0
  fi

  # User-local install from GitHub releases (no sudo needed). Candidate
  # paths, gh_repo, asset filename template and the pinned fallback
  # version all come from tools.psv, not hardcoded here.
  info "Installing jadx from GitHub releases..."
  if ! gh_release_download jadx ".zip"; then
    fail "Could not download jadx."
    manual "Download from https://github.com/$(tool_field jadx gh_repo)/releases/latest"
  fi
  local tmp_zip="$GH_DL_FILE"
  local version="$GH_DL_VERSION"

  local install_dir="$HOME/.local/share/jadx"
  rm -rf "$install_dir"
  mkdir -p "$install_dir"
  unzip -qo "$tmp_zip" -d "$install_dir"
  rm -f "$tmp_zip"
  chmod +x "$install_dir/bin/jadx" "$install_dir/bin/jadx-gui" 2>/dev/null || true

  # Add to PATH
  mkdir -p "$HOME/.local/bin"
  ln -sf "$install_dir/bin/jadx" "$HOME/.local/bin/jadx"
  ln -sf "$install_dir/bin/jadx-gui" "$HOME/.local/bin/jadx-gui"
  export PATH="$HOME/.local/bin:$PATH"
  add_to_profile 'export PATH="$HOME/.local/bin:$PATH"'

  if command -v jadx &>/dev/null; then
    ok "jadx $version installed to $install_dir"
  else
    ok "jadx $version installed to $install_dir"
    info "Run: export PATH=\"\$HOME/.local/bin:\$PATH\" to use it now"
  fi
}

install_vineflower() {
  # Check if already available. Candidate paths, the probe list (vineflower,
  # fernflower) and the FERNFLOWER_JAR_PATH env override all come from
  # tools.psv via tool_resolve, not a separately-maintained candidate list.
  local resolved
  if resolved=$(tool_resolve vineflower); then
    ok "Vineflower/Fernflower already available: $resolved"
    return 0
  fi

  # Try brew
  if [[ "$PKG_MANAGER" == "brew" ]]; then
    info "Installing vineflower via Homebrew..."
    if brew install vineflower 2>/dev/null; then
      ok "Vineflower installed via Homebrew"
      return 0
    fi
    info "Homebrew formula not available, falling back to direct download."
  fi

  # Download JAR from GitHub releases (no sudo needed). gh_repo, asset
  # filename template and the pinned fallback version all come from
  # tools.psv, not hardcoded here.
  info "Installing Vineflower from GitHub releases..."
  if ! gh_release_download vineflower ".jar"; then
    fail "Could not download Vineflower."
    manual "Download from https://github.com/$(tool_field vineflower gh_repo)/releases/latest"
  fi
  local tmp_jar="$GH_DL_FILE"
  local version="$GH_DL_VERSION"
  local install_dir="$HOME/.local/share/vineflower"
  mkdir -p "$install_dir"
  mv "$tmp_jar" "$install_dir/vineflower.jar"

  # Create wrapper script
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/vineflower" <<'WRAPPER'
#!/usr/bin/env bash
exec java -jar "$HOME/.local/share/vineflower/vineflower.jar" "$@"
WRAPPER
  chmod +x "$HOME/.local/bin/vineflower"

  export PATH="$HOME/.local/bin:$PATH"
  export FERNFLOWER_JAR_PATH="$install_dir/vineflower.jar"
  add_to_profile 'export PATH="$HOME/.local/bin:$PATH"'
  add_to_profile "export FERNFLOWER_JAR_PATH=\"$install_dir/vineflower.jar\""

  ok "Vineflower $version installed to $install_dir/vineflower.jar"
  info "FERNFLOWER_JAR_PATH set to $install_dir/vineflower.jar"
}

install_adb() {
  if command -v adb &>/dev/null; then
    ok "adb already installed"
    return 0
  fi

  case "$PKG_MANAGER" in
    brew)    info "Installing adb via Homebrew..."; brew install android-platform-tools ;;
    apt)     pkg_install "adb" ;;
    dnf)     pkg_install "android-tools" ;;
    pacman)  pkg_install "android-tools" ;;
    *)       manual "Install Android SDK Platform Tools from https://developer.android.com/tools/releases/platform-tools" ;;
  esac

  if command -v adb &>/dev/null; then
    ok "adb installed"
  else
    fail "adb installation may have failed."
    exit 1
  fi
}

# =====================================================================
# Dispatch
# =====================================================================

case "$DEP" in
  java)        install_java ;;
  jadx)        install_jadx ;;
  vineflower|fernflower)  install_vineflower ;;
  adb)         install_adb ;;
  *)
    echo "Error: Unknown dependency '$DEP'" >&2
    echo "Available: java, jadx, vineflower, adb" >&2
    exit 1
    ;;
esac
