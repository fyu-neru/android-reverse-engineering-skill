# Setup Guide: Dependencies for Android Reverse Engineering

## Java JDK 17+

jadx requires Java 17 or later.

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install openjdk-17-jdk
```

### Fedora

```bash
sudo dnf install java-17-openjdk-devel
```

### Arch Linux

```bash
sudo pacman -S jdk17-openjdk
```

### macOS (Homebrew)

```bash
brew install openjdk@17
```

After installation on macOS, follow the symlink instructions printed by Homebrew, or add to your shell profile:

```bash
export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
```

### Verify

```bash
java -version
# Should show version 17.x or higher
```

---

## Digest Verification

When `install-dep.sh`/`install-dep.ps1` install jadx or Vineflower from GitHub Releases, they verify the downloaded file's sha256 against the digest GitHub reports for that exact release asset before installing it — a mismatch refuses to install (exits non-zero, naming both the expected and actual digest) rather than proceeding with a possibly-bad file.

**What this defends against:** download corruption, a truncated transfer, an asset that got swapped between the moment the release tag was resolved and the moment the file was downloaded, and CDN-level tampering in transit.

**What this does *not* defend against:** GitHub's own release infrastructure being compromised, or a maintainer replacing a release asset — in either case the digest GitHub reports would be updated right along with the file, so the verification would still pass. Catching that requires build provenance (a signed attestation tying the artifact back to the exact source commit and workflow run that produced it), and neither of the two digest-verified downloads this plugin actually performs (jadx, Vineflower) has one: as of this writing, [jadx's `release.yml`](https://github.com/skylot/jadx/blob/master/.github/workflows/release.yml) publishes through `softprops/action-gh-release` with no `attest-build-provenance` step, no cosign/sigstore signing, and no separate checksums file to cross-check against; [Vineflower's `release.yml`](https://github.com/Vineflower/vineflower/blob/master/.github/workflows/release.yml) doesn't even go that far — on a tag push it only builds and publishes to Sonatype/Maven Central, with no step anywhere in its CI that uploads a jar to a GitHub release, so the jars attached to its GitHub releases carry no CI-recorded provenance at all. Digest verification is real protection against the failure modes listed above — it is not a substitute for provenance, and treating it as one would be a false sense of security this plugin does not claim.

The pinned fallback version used when the GitHub API is unreachable or rate-limited (`tools.psv`'s `pin`/`pin_digest` columns) is verified the same way, against a digest recorded when that version was pinned — see the comment above the `tools.psv` header for the retrieval date.

---

## jadx

jadx is the Java decompiler used to convert APK/JAR/AAR files to readable Java source.

### Option 1: GitHub Releases (recommended)

1. Go to <https://github.com/skylot/jadx/releases/latest>
2. Download the `jadx-<version>.zip` file (not the source archive)
3. Extract and add to PATH:

```bash
unzip jadx-*.zip -d ~/jadx
export PATH="$HOME/jadx/bin:$PATH"
# Add the export line to your ~/.bashrc or ~/.zshrc for persistence
```

### Option 2: Homebrew (macOS / Linux)

```bash
brew install jadx
```

### Option 3: Build from source

```bash
git clone https://github.com/skylot/jadx.git
cd jadx
./gradlew dist
# Binaries will be in build/jadx/bin/
export PATH="$(pwd)/build/jadx/bin:$PATH"
```

### Verify

```bash
jadx --version
```

---

## Vineflower (optional, recommended)

[Vineflower](https://github.com/Vineflower/vineflower) is an actively maintained Java decompiler with published releases. It produces better output than jadx on complex Java constructs, lambdas, and generics.

### Option 1: Vineflower from GitHub Releases (recommended)

1. Go to <https://github.com/Vineflower/vineflower/releases/latest>
2. Download `vineflower-<version>.jar`
3. Place it and set the environment variable:

```bash
mkdir -p ~/vineflower
mv vineflower-*.jar ~/vineflower/vineflower.jar
export VINEFLOWER_JAR="$HOME/vineflower/vineflower.jar"
# Add the export to ~/.bashrc or ~/.zshrc for persistence
```

### Option 2: Build Vineflower from source

```bash
git clone https://github.com/Vineflower/vineflower.git
cd vineflower
./gradlew build
# Produces: build/libs/vineflower-<version>.jar
export VINEFLOWER_JAR="$(pwd)/build/libs/vineflower-<version>.jar"
```

### Option 3: Homebrew (Vineflower)

```bash
brew install vineflower
```

### Verify

```bash
java -jar "$VINEFLOWER_JAR" --version
```

> **Note**: Vineflower only works on JVM bytecode (JAR, class files) — it cannot read an APK or a raw `.dex` directly. To point it at an APK, convert with **dex2jar** first (see below); this is a manual step, not something `install-dep.sh`/`check-deps.sh` set up for you.

---

## Manual Fallback Tools

jadx handles APK, DEX, AAB, XAPK and APKM natively, so the tools below are **not** dependencies of this plugin — `install-dep.sh` cannot install them and `check-deps.sh` does not check for them. They stay useful for the specific cases jadx does not cover; install and invoke each one directly when its trigger applies.

### apktool — when jadx's resource decoding falls short

**Trigger:** jadx decompiles Java/Kotlin code well, but its own documentation describes its resource decoding as partial, and real APKs exist where it fails outright on resources while the code decompiles fine — see [jadx issue #1517](https://github.com/skylot/jadx/issues/1517), a resource-only-APK failure. Reach for apktool specifically to decode `AndroidManifest.xml`, layouts, and other binary XML/resources when jadx's `resources/` output is empty, garbled, or errors out.

```bash
# Ubuntu/Debian
sudo apt install apktool

# macOS
brew install apktool

# Manual: https://apktool.org/docs/install
```

Worked example — decode just the resources jadx couldn't:

```bash
apktool d app.apk -o app-resources/
# Inspect the real, non-obfuscated XML apktool produces:
cat app-resources/AndroidManifest.xml
ls app-resources/res/layout/
```

### dex2jar — when you want Vineflower to read an APK

**Trigger:** Vineflower decompiles JVM bytecode (`.jar`/`.class`) only — jadx is the default decompiler precisely because it reads DEX/APK directly. Reach for dex2jar only when you specifically want Vineflower's output (it is often cleaner on complex generics, lambdas, and switch-expressions) and the input is DEX-based.

### GitHub Releases

1. Go to <https://github.com/ThexXTURBOXx/dex2jar/releases/latest>
2. Download and extract:

```bash
unzip dex-tools-*.zip -d ~/dex2jar
export PATH="$HOME/dex2jar:$PATH"
```

### Homebrew

```bash
brew install dex2jar
```

### Verify

```bash
d2j-dex2jar --help
```

Worked example — convert then decompile with Vineflower:

```bash
# Convert APK (or DEX) to JAR
d2j-dex2jar -f -o output.jar app.apk

# Then decompile with Vineflower
java -jar vineflower.jar output.jar decompiled/
```

### APKEditor — when an XAPK's OBB files make jadx fail

**Trigger:** jadx accepts `.xapk` directly, but only for the split APKs inside it — it does not handle OBB expansion files an XAPK can bundle, and an XAPK that ships OBB data alongside its APKs can make jadx fail on the archive as a whole rather than silently skipping the OBB. Reach for [APKEditor](https://github.com/REAndroid/APKEditor) to merge the XAPK's split APKs into one standalone APK first, and to pull the OBB files out separately for inspection.

```bash
# Requires Java 17+. Download the latest APKEditor-<version>.jar:
# https://github.com/REAndroid/APKEditor/releases/latest
```

Worked example — merge an XAPK's splits, then hand jadx a single APK:

```bash
# Merge the split APKs inside the XAPK into one installable APK
java -jar APKEditor.jar m -i app.xapk -o app-merged.apk

# OBB files are not part of the merge — extract them yourself, the XAPK
# is a plain ZIP:
unzip -l app.xapk | grep '\.obb$'
unzip -j app.xapk '*.obb' -d obb/

# Now jadx can decompile the merged APK normally
jadx -d output app-merged.apk
```

---

## Optional Tools

### python3 (required by recover-kotlin-names.sh and lookup-name.sh)

`recover-kotlin-names.sh` and `lookup-name.sh` (Phase 3.5, Kotlin name
recovery) are internally embedded Python scripts — `python3` must be a
working interpreter for either one to run at all. It is declared as an
**optional** dependency in `tools.psv`/`check-deps.sh`/`check-deps.ps1` only
because most of this plugin's workflow (Phases 0–2, 4–5) never touches
Python; it becomes a **required** dependency starting 2.2.0, once the
analysis scripts migrate onto this same resolution layer.

```bash
# Ubuntu/Debian
sudo apt install python3

# macOS (usually already present)
brew install python3

# Windows
winget install Python.Python.3
```

**The stub trap on Windows:** if Python was never installed, typing
`python3` (or `python`) at a prompt does not fail with "command not found"
— it silently launches the Microsoft Store's listing for Python instead of
running anything. That app-execution-alias stub still resolves via `PATH`
(`command -v python3` / `Get-Command python3` both find it), so a
dependency check that only asks "is python3 on PATH" reports this stub as
installed. Actually running it exits non-zero (49) immediately, with no
version string on stdout — the resolution layer detects this by executing
`<candidate> -c "import sys; print(sys.version_info[0])"` and requiring
both a zero exit code and `3` as the output, so this exact stub is never
accepted.

**Installing Python does not give you a `python3` command on Windows.**
python.org's installer creates `python.exe` and `pythonw.exe` — and a
`python3.dll`, but no `python3.exe`. The Store stub therefore stays the
only thing on `PATH` under that name even after a successful install.
This is why `tools.psv`'s python3 row probes `python3,python,py` and
carries `verify=python3`: resolution runs each name in turn and walks
past any that does not answer as Python 3, instead of stopping at the
first one that merely exists. Before that, `check-deps` reported
`[MISSING] python3` on a machine with Python 3.12.10 installed.

### Verify

```bash
# Linux / macOS
python3 -c "import sys; print(sys.version_info)"
```

```powershell
# Windows — python3 is the Store stub even when Python is installed
python -c "import sys; print(sys.version_info)"
```

If this opens the Microsoft Store instead of printing a version tuple, no
interpreter is installed yet — install one with the commands above. To
see what this plugin resolves, run `check-deps.sh` / `check-deps.ps1`:
the `[OK] python3 <version>` line names the version it actually ran.

### adb (Android Debug Bridge)

Useful for pulling APKs directly from a connected Android device.

```bash
# Ubuntu/Debian
sudo apt install adb

# macOS
brew install android-platform-tools
```

Pull an APK from a device:

```bash
# List installed packages
adb shell pm list packages | grep <keyword>

# Get APK path
adb shell pm path com.example.app

# Pull the APK
adb pull /data/app/com.example.app-xxxx/base.apk ./app.apk
```

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `jadx: command not found` | Ensure the jadx `bin/` directory is in your `$PATH` |
| `Error: Could not find or load main class` | Java is missing or wrong version — verify with `java -version` |
| jadx runs out of memory on large APKs | Increase heap: `jadx -Xmx4g -d output app.apk` or set `JAVA_OPTS="-Xmx4g"` |
| Decompiled code has many `// Error` comments | Try `--show-bad-code` to see partial output, or use `--deobf` for obfuscated apps |
| Vineflower hangs on a method | Use `-mpm=60` to set a 60-second timeout per method |
| Vineflower JAR not found | Set `VINEFLOWER_JAR` env variable to the full path of the JAR |
| dex2jar fails with `ZipException` | The APK may have a non-standard ZIP structure — try `jadx` instead |
| Typing `python3` opens the Microsoft Store | No real Python interpreter is installed — that's the Windows app-execution-alias stub, not python. Install Python 3 (see "python3" above), then re-run `check-deps` |
| `recover-kotlin-names.sh`/`lookup-name.sh` fail immediately | Both are embedded Python scripts; run `check-deps.sh`/`check-deps.ps1` and confirm `python3` shows `[OK]`, not `[MISSING]` |
