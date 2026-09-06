# Vineflower CLI Reference

[Vineflower](https://github.com/Vineflower/vineflower) is an actively maintained analytical Java decompiler with published releases on GitHub and Maven Central. It does well on complex Java constructs — modern language features (records, sealed classes, pattern matching), lambdas, generics, and switch expressions — and is the engine this plugin's `--engine vineflower` and `--engine both` options run.

## When to Use Vineflower vs jadx

| Scenario | Recommended |
|---|---|
| APK with resources needed | jadx |
| Standard Java JAR/library | Vineflower |
| jadx output has warnings/errors on specific classes | Vineflower on those classes |
| Complex lambdas, generics, streams | Vineflower |
| Large APK (>50MB), quick overview | jadx |
| Obfuscated Android app | jadx first, Vineflower on problem areas |
| Both decompilers available | Use `--engine both` and compare |

## Basic Usage

```bash
java -jar vineflower.jar [options] <source>... <destination>
```

- `<source>` — JAR file, class file, or directory containing class files
- `<destination>` — output directory

For a JAR input, Vineflower produces a JAR in the destination containing `.java` source files. Extract it with `unzip` to browse the sources.

## Key Options

Options use the format `-<key>=<value>`. Boolean options: `1` = enabled, `0` = disabled.

| Option | Default | Description |
|---|---|---|
| `-dgs=1` | 0 | Decompile generic signatures (recommended) |
| `-ren=1` | 0 | Rename obfuscated identifiers |
| `-mpm=60` | 0 | Max seconds per method — prevents hangs (recommended) |
| `-hes=0` | 1 | Show empty super() calls |
| `-hdc=0` | 1 | Show empty default constructors |
| `-udv=1` | 1 | Use debug variable names if available |
| `-ump=1` | 1 | Use debug parameter names if available |
| `-lit=1` | 0 | Output numeric literals as-is |
| `-asc=1` | 0 | Encode non-ASCII as unicode escapes |
| `-lac=1` | 0 | Decompile lambdas as anonymous classes |
| `-log=WARN` | INFO | Reduce output verbosity |
| `-e=<lib>` | — | Add library for context (not decompiled, improves type resolution) |

## Recommended Presets

### General use

```bash
java -jar vineflower.jar -dgs=1 -mpm=60 input.jar output/
```

### Obfuscated code

```bash
java -jar vineflower.jar -dgs=1 -ren=1 -mpm=60 input.jar output/
```

### Maximum detail

```bash
java -jar vineflower.jar -dgs=1 -hes=0 -hdc=0 -mpm=60 input.jar output/
```

### With Android SDK context (better type resolution)

```bash
java -jar vineflower.jar -dgs=1 -mpm=60 -e=$ANDROID_HOME/platforms/android-34/android.jar input.jar output/
```

## Working with APK Files

Vineflower cannot read APK/DEX files directly. Use dex2jar first:

```bash
# Step 1: Convert DEX to JAR
d2j-dex2jar -f -o app-converted.jar app.apk

# Step 2: Decompile with Vineflower
java -jar vineflower.jar -dgs=1 -mpm=60 app-converted.jar output/

# Step 3: Extract the resulting source JAR
unzip -o output/app-converted.jar -d output/sources/
```

`decompile.sh --engine vineflower` does **not** do this conversion for you: as of 2.0.0 it only accepts `.jar`, `.aar`, and `.class` input and refuses anything else outright (dex2jar is no longer part of this plugin's pipeline — see `setup-guide.md`'s "Manual Fallback Tools" section). Run the two steps above by hand first if you need Vineflower's output from an APK.

## Supported Input Formats

| Format | Direct support | Via dex2jar |
|---|---|---|
| `.jar` | Yes | — |
| `.class` | Yes | — |
| `.zip` (with classes) | Yes | — |
| `.apk` | No | Yes |
| `.dex` | No | Yes |
| `.aar` | No | Yes |

## Output Format

- **JAR input** → Produces `<destination>/<input-name>.jar` containing `.java` files
- **Class file input** → Produces `.java` files directly in the destination
- **No resource decoding** — Vineflower only produces Java source, never XML/resources

## Releases and Maintenance

- Published releases on GitHub and Maven Central
- Active bug fixes and community maintenance
- Stable CLI interface across releases
