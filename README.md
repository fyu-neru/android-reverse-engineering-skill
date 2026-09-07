# Android Reverse Engineering & API Extraction — Claude Code skill

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![GitHub stars](https://img.shields.io/github/stars/SimoneAvogadro/android-reverse-engineering-skill?style=social)](https://github.com/SimoneAvogadro/android-reverse-engineering-skill/stargazers) [![GitHub last commit](https://img.shields.io/github/last-commit/SimoneAvogadro/android-reverse-engineering-skill)](https://github.com/SimoneAvogadro/android-reverse-engineering-skill/commits/master)

A Claude Code skill that decompiles Android packages (APK, XAPK, APKM, APKS, AAB, DEX, ZIP, JAR, AAR) and **extracts the HTTP APIs** used by the app — Retrofit endpoints, OkHttp calls, hardcoded URLs, authentication patterns — so you can document and reproduce them without the original source code.

> **First-class Kotlin support**: modern Android apps are Kotlin/KMP, heavily obfuscated with R8. This skill recovers the **original Kotlin class names** from metadata R8 cannot strip, and extracts APIs from **Ktor**, **Apollo (GraphQL)** and **Koin** — not just the classic Retrofit/OkHttp stack. See [Kotlin name recovery](#kotlin-name-recovery-r8-deobfuscation) below.

> **Windows / PowerShell support (experimental)**: The `*.ps1` scripts alongside the bash ones are a recent community contribution, still being stabilised. For any issues please open an issue on **this** repository (not on the contributors' upstream forks): the PowerShell scripts are maintained here by [@SimoneAvogadro](https://github.com/SimoneAvogadro).

## Table of Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Repository Structure](#repository-structure)
- [References](#references)
- [Acknowledgments](#acknowledgments)
- [Disclaimer](#disclaimer)
- [License](#license)

## What it does

| Capability | Description |
|------------|-------------|
| **Fingerprint first (Phase 0)** | Triage an APK/XAPK in seconds — detect the framework (Flutter / React Native / Cordova / Xamarin / native-Kotlin), HTTP stack, obfuscation level and native libs *before* spending time on a full decompile |
| **Decompile** | APK, XAPK, APKM, APKS, AAB, DEX, ZIP, JAR, and AAR files using jadx and Vineflower (single engine or side-by-side comparison) |
| **Recover Kotlin names** | Rebuild original `*Repository` / `*ViewModel` / `*UseCase` class names from R8-obfuscated binaries using Kotlin metadata that R8 cannot strip |
| **Extract APIs** | Retrofit, OkHttp, Volley **and modern Kotlin/KMP stacks: Ktor, Apollo (GraphQL), Koin DI** — endpoints, hardcoded URLs, auth headers, tokens and HMAC request-signing schemes |
| **Trace call flows** | From Activities/Fragments through ViewModels and repositories down to HTTP calls |
| **Analyze structure** | Manifest, packages, architecture patterns |
| **Handle obfuscation** | R8-resistant path/URL extraction plus strategies for navigating ProGuard/R8 output |

## Requirements

**Required:**

- Java JDK 17+
- [jadx](https://github.com/skylot/jadx) (CLI)

**Optional (recommended):**

- [Vineflower](https://github.com/Vineflower/vineflower) — better output on complex Java code (accepts `.jar`, `.aar`, and `.class` input only; jadx handles everything else, including APKs)
- **`python3`** — required specifically by `recover-kotlin-names.sh` and `lookup-name.sh` (Kotlin name recovery, below), which are internally embedded Python. Not needed for decompiling, fingerprinting, or API extraction. On Windows, typing `python3` with nothing installed opens the Microsoft Store instead of running anything; `check-deps.sh`/`check-deps.ps1` actually execute the resolved interpreter to catch that stub rather than trusting the name on PATH.

See `plugins/android-reverse-engineering/skills/android-reverse-engineering/references/setup-guide.md` for detailed installation instructions, including manual fallback tools (dex2jar, apktool) for edge cases jadx doesn't cover.

## Installation

### From GitHub (recommended)

Inside Claude Code, run:

```text
/plugin marketplace add SimoneAvogadro/android-reverse-engineering-skill
/plugin install android-reverse-engineering@android-reverse-engineering-skill
```

The skill will be permanently available in all future sessions.

### From a local clone

```bash
git clone https://github.com/SimoneAvogadro/android-reverse-engineering-skill.git
```

Then in Claude Code:

```text
/plugin marketplace add /path/to/android-reverse-engineering-skill
/plugin install android-reverse-engineering@android-reverse-engineering-skill
```

## Usage

### Slash command

```text
/decompile path/to/app.apk
```

This runs the full workflow: dependency check, decompilation, and initial structure analysis.

### Natural language

The skill activates on phrases like:

- "Decompile this APK"
- "Reverse engineer this Android app"
- "Extract API endpoints from this app"
- "Follow the call flow from LoginActivity"
- "Analyze this AAR library"

### Manual scripts

The scripts can also be used standalone:

```bash
# Check dependencies
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/check-deps.sh

# Install a missing dependency (auto-detects OS and package manager)
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/install-dep.sh jadx
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/install-dep.sh vineflower

# Fingerprint an APK/XAPK BEFORE decompiling (Phase 0 triage):
# framework, HTTP stack, obfuscation level, native libs, notable SDKs
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/fingerprint.sh app.apk

# Decompile APK with jadx (default)
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/decompile.sh app.apk

# Decompile XAPK (jadx reads it natively, merged into one source tree)
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/decompile.sh app-bundle.xapk

# Decompile with Vineflower (accepts .jar/.aar/.class only — use jadx for APKs)
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/decompile.sh --engine vineflower library.jar

# Run both engines and compare (also requires .jar/.aar/.class input)
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/decompile.sh --engine both --deobf library.jar

# Find API calls — defaults to a full scan across every supported stack
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/find-api-calls.sh output/sources/
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/find-api-calls.sh output/sources/ --retrofit
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/find-api-calls.sh output/sources/ --urls

# Modern Kotlin/KMP stacks and obfuscation-resistant extraction
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/find-api-calls.sh output/sources/ --ktor    # Ktor client
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/find-api-calls.sh output/sources/ --apollo  # Apollo / GraphQL
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/find-api-calls.sh output/sources/ --paths   # quoted path literals that survive R8 inlining
```

### Kotlin name recovery (R8 deobfuscation)

Most real-world Kotlin/KMP apps ship through R8, so the decompiled classes come
out as `a.b.c`. R8 renames the JVM symbols but **cannot strip the Kotlin
metadata strings** — the Kotlin runtime (reflection, coroutines) needs the
original fully-qualified names at runtime. This skill mines those
`@DebugMetadata` / `@Metadata` annotations to rebuild an `obfuscated → real`
class-name map. On a typical app it recovers ~100 % of the
`*Repository` / `*ViewModel` / `*UseCase` / `*Impl` classes you actually want to
read.

> **Requires `python3`**: both scripts below are internally embedded Python.
> Run `check-deps.sh`/`check-deps.ps1` first and confirm `python3` shows
> `[OK]`. On Windows, a `python3` that opens the Microsoft Store instead of
> running is the app-execution-alias stub, not a real interpreter — see
> setup-guide.md.

```bash
# 1. Build the mapping from the decompiled sources
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/recover-kotlin-names.sh output/sources/ output/names/
#    → output/names/mapping.tsv, mapping.json, by_package/

# 2. Query it: resolve an obfuscated name, search by real name, or grep
#    the sources with each hit annotated with its recovered class name
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/lookup-name.sh output/names/ LoginRepository
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/lookup-name.sh output/names/ -o a.b.c
bash plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts/lookup-name.sh output/names/ --grep 'login' output/sources/
```

## Repository Structure

```text
android-reverse-engineering-skill/
├── .claude-plugin/
│   └── marketplace.json                    # Marketplace catalog
├── plugins/
│   └── android-reverse-engineering/
│       ├── .claude-plugin/
│       │   └── plugin.json                 # Plugin manifest
│       ├── skills/
│       │   └── android-reverse-engineering/
│       │       ├── SKILL.md                # Core workflow (Phase 0–5)
│       │       ├── references/
│       │       │   ├── setup-guide.md
│       │       │   ├── jadx-usage.md
│       │       │   ├── vineflower-usage.md
│       │       │   ├── api-extraction-patterns.md
│       │       │   ├── kotlin-name-recovery.md
│       │       │   ├── third_party_hosts.txt   # denylist for first/third-party bucketing
│       │       │   └── call-flow-analysis.md
│       │       └── scripts/
│       │           ├── check-deps.sh       # Bash
│       │           ├── check-deps.ps1      # PowerShell
│       │           ├── install-dep.sh
│       │           ├── install-dep.ps1
│       │           ├── decompile.sh
│       │           ├── decompile.ps1
│       │           ├── fingerprint.sh          # Phase 0 — pre-decompile triage
│       │           ├── recover-kotlin-names.sh # R8 → real Kotlin class names
│       │           ├── lookup-name.sh          # query the recovered name map
│       │           ├── find-api-calls.sh
│       │           ├── find-api-calls.ps1
│       │           └── lib/                    # tool-resolution layer
│       │               ├── tools.sh            # Bash: locate/verify tools from tools.psv
│       │               ├── Tools.ps1           # PowerShell: locate/verify tools from tools.psv
│       │               └── tools.psv           # tool registry: paths, env vars, GitHub release info
│       └── commands/
│           └── decompile.md                # /decompile slash command
├── LICENSE
└── README.md
```

## References

- [jadx — Dex to Java decompiler](https://github.com/skylot/jadx)
- [Vineflower — actively-maintained Fernflower community fork](https://github.com/Vineflower/vineflower)
- [dex2jar — DEX to JAR converter](https://github.com/ThexXTURBOXx/dex2jar) — not a dependency; a manual fallback for converting an APK so Vineflower can read it (see setup-guide.md)
- [apktool — Android resource decoder](https://apktool.org/) — not a dependency; a manual fallback for the cases where jadx's own resource decoding falls short (see setup-guide.md)

## Acknowledgments

Thanks to the contributors who have shaped this skill:

- [@tajchert](https://github.com/tajchert) — Phase 0 fingerprinting, R8-resistant Kotlin name recovery (`recover-kotlin-names.sh`, `lookup-name.sh`), and Ktor / Apollo / Koin / HMAC extraction patterns (#16)
- [@philjn](https://github.com/philjn) — Native Windows / PowerShell support (`check-deps.ps1`, `install-dep.ps1`, `decompile.ps1`, `find-api-calls.ps1`) and split/bundled APK detection in `decompile.sh` (#8)
- [@txhno](https://github.com/txhno) — Migration to the maintained [`ThexXTURBOXx/dex2jar`](https://github.com/ThexXTURBOXx/dex2jar) fork (#12)
- [@muqiao215](https://github.com/muqiao215) — Decompile partial-success handling, Fernflower timeout safeguard, intermediate-artifact directory (#10)
- [@kevinaimonster](https://github.com/kevinaimonster) — Chinese localization (`SKILL.md` discovery keywords) (#4)

## Disclaimer

This plugin is provided strictly for **lawful purposes**, including but not limited to:

- Security research and authorized penetration testing
- Interoperability analysis permitted under applicable law (e.g., EU Directive 2009/24/EC, US DMCA §1201(f))
- Malware analysis and incident response
- Educational use and CTF competitions

**You are solely responsible** for ensuring that your use of this tool complies with all applicable laws, regulations, and terms of service. Unauthorized reverse engineering of software you do not own or do not have permission to analyze may violate intellectual property laws and computer fraud statutes in your jurisdiction.

The authors disclaim any liability for misuse of this tool.

## License

Apache 2.0 — see [LICENSE](LICENSE)
