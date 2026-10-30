# Blender 5.3 for Android — current build guide

This document describes how to reproduce this fork's Android builds on a Samsung
Galaxy S24 Ultra. It covers both profiles (`lite` and `full`), documents the
fast iteration loop that makes day-to-day work possible, and records the
mistakes that have already cost time or data so they are not repeated.
`ANDROID_PORT_SPEC.md` remains only as a record of the architecture planned at
the start of the port.

> **Read section 16 before touching the environment.** It lists traps that have
> already destroyed an entire WSL2 distribution and stalled builds for tens of
> minutes with no error message.

## 1. Verified state

### `full` profile — August 20, 2026

The complete APK was built, signed and installed on the device:

```text
build/android-apk/Blender-5.3.0-Alpha-Android-arm64-S24Ultra-FULL-20260820.apk
Size: 173,751,441 bytes
SHA-256: 8912eb977ff364414c798a4de801f5c2b4f9ae054b7fc62eb0b3d2427e360755
Application ID: org.blender.blender.s24full
```

Contents and checks performed on the package:

- valid v2/v3 signature (certificate `CN=Android Debug`);
- ZIP integrity confirmed with `unzip -t`;
- 129 native libraries, 342 MB before compression;
- 62 MB of script/Python runtime;
- Cycles add-on bundled (`scripts/addons_core/cycles`);
- `libblender.so` is an `ELF 64-bit LSB shared object, ARM aarch64`.

Features actually present, confirmed against the build's `CMakeCache.txt` and
against the binary's symbols and `NEEDED` entries:

| Feature | Flag | Evidence in the binary |
| --- | --- | --- |
| Cycles (CPU, NEON) | `WITH_CYCLES=ON` | 10,774 `ccl::` symbols, including `ccl::PathTrace` |
| Embree | `WITH_CYCLES_EMBREE=ON` | `NEEDED libembree4.so` |
| FFmpeg | `WITH_CODEC_FFMPEG=ON` | `NEEDED libavcodec.so`, plus `libavformat`/`libavutil`/`libswscale` in the APK |
| USD | `WITH_USD=ON` | `NEEDED libusd_ms.so` (monolithic) |
| OpenVDB + NanoVDB | `WITH_OPENVDB=ON` | `NEEDED libopenvdb.so` |
| Alembic | `WITH_ALEMBIC=ON` | `NEEDED libAlembic.so` |
| MaterialX | `WITH_MATERIALX=ON` | `NEEDED libMaterialXCore.so`, `libMaterialXFormat.so` |
| OpenSubdiv | `WITH_OPENSUBDIV=ON` | `libosdCPU.so`, `libosdGPU.so` in the APK |
| Python 3.13 + NumPy | `WITH_PYTHON=ON`, `WITH_PYTHON_NUMPY=ON` | `libpython3.13.so` + `site-packages/numpy` |
| TBB, OIIO, OCIO, Potrace, Freestyle, Audaspace | `ON` | corresponding libraries in the APK |

Two honest caveats about the `full` profile:

- **LLVM** is compiled and located (`WITH_LLVM=ON`), but the binary contains no
  `llvm::` symbol at all. In Blender, LLVM is consumed by OSL, and
  `WITH_CYCLES_OSL` is still `OFF` in `android_features_common.cmake`. LLVM is
  ready for the day OSL is enabled, at no cost to the APK.
- **Rubberband** is found (`RUBBERBAND_LIBRARY` resolves) but appears in no
  `NEEDED` entry and no undefined symbol references it, so it was not packaged.
  Nothing on the active code path uses it in this configuration.

### `lite` profile — validated in use on the device

The `lite` APK (`org.blender.blender.s24final`, ~102 MB) reached Blender's full
interface on the S24 Ultra and remains the behavioral reference:

- splash screen and Quick Setup for 5.3.0 Alpha;
- Python initialized (`WM_init: Python ready`);
- menus, workspaces, headers, tools, Outliner, properties, timeline and gizmos
  all present;
- visual scale corrected for Blender's 160 DPI profile;
- Vulkan viewport rendering the default scene;
- file browser recognizing internal storage, Downloads, Documents, Pictures,
  Videos and Music.

## 2. Layout in use

### On Windows

| Path | Purpose | Keep? |
| --- | --- | --- |
| `G:\PROGRAMING\BLENDER\blender-android` | second clone: offline copy of the history, not edited (section 5) | yes |
| `G:\PROGRAMING\BLENDER\blender-android\build\android-apk` | destination for produced APKs | yes, contents ignored by Git |
| `G:\WSL\Ubuntu-26.04` | VHDX of the WSL2 build distribution | yes |
| `G:\PROGRAMING\BLENDER\blender-android-legacy` | legacy tree, outside the current flow | preserve until manually reviewed |

The APK is ignored by Git: it is a reproducible artifact, not source.

### In WSL2 (`Ubuntu-26.04`)

| Path | Purpose |
| --- | --- |
| `/root/blender-android-fast` | **the working copy**: a real Git clone, edited here, built here (section 5) |
| `/root/blender_android_deps` | dependencies, host tools, builds and APK stages |
| `/root/android-sdk` | Android SDK and NDK |
| `/root/ci` | build driver scripts (see section 9) |
| `/root/logs` | logs for each step |
| `/mnt/g/PROGRAMING/BLENDER/blender-android` | access to the Windows repository |

Subdirectories of `/root/blender_android_deps`:

| Directory | Contents |
| --- | --- |
| `lib/android_arm64` | prefix of the 58 ARM64 dependencies (~24 GB with LLVM) |
| `build_host_tools_full` / `_lite` | native `makesdna`, `makesrna`, `datatoc`, `msgfmt`, `shader_tool` |
| `build_android_full` / `_lite` | objects and `lib/libblender.so` for Android ARM64 |
| `android_apk_stage_full-s24full` | full APK stage |
| `android_deps_build` | downloads and dependency build trees |
| `android_deps_build/host` | host tools that must run on the build machine (`ispc`) |

## 3. Disk requirements — read before starting

The `full` build **does not fit** in 40 GB. Measured consumption:

| Item | Size |
| --- | --- |
| `lib/android_arm64` (57 deps) | 24 GB, of which 19 GB is LLVM alone |
| `android_deps_build` (sources + trees) | ~30 GB |
| `build_android_full` | ~20 GB |
| `libblender.so` before stripping | 1.75 GB |
| Total distribution size after the build | ~81 GB |

Reserve **120 GB free** on the volume hosting the WSL2 VHDX. If the VHDX sits on
a tight disk, move the distribution **before** starting — and read section 16.1,
because this is exactly where an entire distribution was lost.

## 4. Host dependencies

The environment that produced the `full` APK:

- WSL2 with Ubuntu 26.04 LTS, VHDX at `G:\WSL\Ubuntu-26.04`;
- 16 vCPUs, 31 GB of RAM;
- CMake 4.2.3, Ninja, Meson;
- GCC 15 / G++ 15 (`ANDROID_HOST_CC=gcc-15`);
- OpenJDK 17 (`/usr/lib/jvm/java-17-openjdk-amd64`);
- Android SDK at `/root/android-sdk`, NDK `28.2.13676358`, Build Tools `35.0.1`,
  platform `android-35`;
- CPython **3.13.13 built from source** as the host interpreter;
- `pkgconf`, `patchelf`, `nasm`, `yasm`, autotools, `libtool`, `rsync`, `zip`,
  `unzip`, `git`;
- host Blender libraries in `lib/linux_x64`.

Provisioning a clean distribution:

```bash
apt-get update
apt-get install -y \
  build-essential gcc-15 g++-15 cmake ninja-build meson pkgconf patchelf \
  nasm yasm autoconf automake libtool libtool-bin bison flex gperf texinfo \
  curl wget git git-lfs zip unzip xz-utils bzip2 rsync file \
  openjdk-17-jdk python3 python3-pip python3-venv python3-setuptools \
  libssl-dev zlib1g-dev libffi-dev libsqlite3-dev libbz2-dev liblzma-dev \
  libreadline-dev libncurses-dev uuid-dev tk-dev
```

SDK and NDK:

```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
SDK=/root/android-sdk
curl -sL -o /tmp/cmdline-tools.zip \
  https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip
mkdir -p "$SDK/cmdline-tools"
unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-x
mv /tmp/cmdline-tools-x/cmdline-tools "$SDK/cmdline-tools/latest"
SM="$SDK/cmdline-tools/latest/bin/sdkmanager"
yes | "$SM" --sdk_root="$SDK" --licenses
"$SM" --sdk_root="$SDK" \
  "ndk;28.2.13676358" "platform-tools" "build-tools;35.0.1" "platforms;android-35"
```

Ubuntu 26.04 has **no `python3.13` package** (3.14 is the default). Do not try to
substitute it: `deps/build.sh python` builds the host 3.13 automatically into
`android_deps_build/work/python-host-install`. See section 16.4.

`build_files/android/env.sh` selects the SDK, NDK, JDK and host compiler. The
central values:

```text
ANDROID_ABI=arm64-v8a
ANDROID_API=31
ANDROID_TARGET_API=34
ANDROID_NDK_VERSION=28.2.13676358
```

## 5. The working copy

`/root/blender-android-fast` is a real Git clone and the **only** copy that gets
edited. It builds from ext4 instead of across the `/mnt/g` 9p mount, and — the
larger point — there is no synchronisation step left to get wrong.

The Windows checkout at `G:\PROGRAMING\BLENDER\blender-android` is a second
clone of the same fork, kept as a reference and an offline copy of the history.
**Do not edit there.** Bring it forward with `git pull` when you want it
current. Nothing is copied between the two any more; they meet at `origin`.

### Why not rsync between them

The earlier workflow copied Windows → WSL2 on every change, then stripped CRLF
and repaired symlinks. Three things made it fragile:

- Work edited on one side could sit unnoticed on the other. That is exactly how
  an uncommitted three-finger-gesture change ended up inside a shipped APK
  while the repository still held the original behaviour — nothing reported it
  until this checkout gained a `.git`.
- The CRLF pass had to be kept away from the Windows tree, so the same command
  was safe in one directory and destructive in another.
- An `rsync --delete` typed with the arguments reversed would erase the main
  project.

One working copy removes all three, and `git status` now answers "am I in sync?"
directly.

### Opening it in VS Code

Install the WSL extension, then either run `code .` from inside
`/root/blender-android-fast`, or press `Ctrl+Shift+P` → "WSL: Connect to WSL"
and open the folder. The editor runs on Windows, the files stay on ext4.

### Repository configuration that must stay

```bash
git -C /root/blender-android-fast config core.fileMode false
```

```bash
git -C /root/blender-android-fast config core.autocrlf input
```

`core.fileMode false` because the tree was seeded from `/mnt/g`, where every
file reports mode 777; without it about 13 000 files show as modified.
`autocrlf input` makes Git compare with CR stripped, which is what replaces the
manual CRLF normalisation this section used to require — a checkout now writes
LF directly, so the shader generator never sees a stray `\r`.

### The path is load-bearing

Keep the directory at `/root/blender-android-fast`. `build_apk.sh` wipes any
build tree whose recorded `CMakeCache.txt` path no longer matches, so moving or
renaming the checkout costs the ~9 GB incremental build.

### What Git does not carry

`lib/` (2.3 GB) and `tests/files/` (~790 MB) are in `.gitignore` and exist in no
clone. They are recoverable from upstream rather than from this repository:

```bash
git submodule update --init lib/linux_x64
```

Everything else in the working tree is either committed or visible in
`git status`. Section 13 covers what must never be committed.

## 6. Build profiles

The toggles live in `build_files/android/android_features_{common,full,lite}.cmake`.

- **`full`** — Cycles (+embree), FFmpeg, USD, MaterialX, OpenVDB, Alembic, LLVM,
  Rubberband, on top of the common core. For the S24 Ultra and other flagships.
- **`lite`** — those heavy features off, plus Freestyle, Audaspace, OpenSubdiv,
  Potrace, NumPy and TBB. For weaker devices and a much smaller APK.

Python stays enabled in both: the interface's menus, headers, panels, operators
and gizmos are registered by the bundled startup scripts. Without Python the
viewport renders but there is no interface.

The host tools must be built **with the same profile** as the target. If
`makesrna` is generated with different flags, the resulting RNA has no
registration callbacks (`Operator`, `Gizmo`) and the application breaks.
`build_apk.sh` already reconfigures the generators on every run to prevent this.

## 7. Building the dependencies

`deps/build.sh` installs each dependency into `lib/android_arm64/<name>`.
Versions come from `build_files/build_environment/cmake/versions.cmake`.

Environment common to every invocation:

```bash
# Stripping the Windows PATH is mandatory — see section 16.2.
PATH="$(printf %s "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"
export PATH
export BUILD_BASE=/root/blender_android_deps
export ANDROID_HOME=/root/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOST_CC=gcc-15 ANDROID_HOST_CXX=g++-15
cd /root/blender-android-fast
```

### `full` profile — in four stages

Building in stages gives checkpoints and allows resuming without repeating work.
Times measured on 16 vCPUs:

```bash
# A — 44 dependencies that do not depend on Python   (38 min)
bash build_files/android/deps/build.sh \
  zlib zstd deflate imath fmt tbb openexr png pugixml jpeg brotli freetype \
  harfbuzz webp tiff openjpeg expat yamlcpp blosc pystring minizipng \
  opencolorio opensubdiv robinmap openimageio embree alembic materialx \
  potrace sqlite libffi openssl lzma bzip2 xml2 eigen sse2neon fribidi \
  abseil vulkan_headers meshoptimizer shaderc ispc oidn

# B — Python, OpenVDB and the video stack            (33 min)
bash build_files/android/deps/build.sh \
  python openvdb ogg vorbis theora opus lame aom x265 vpx x264 ffmpeg

# C — LLVM, can run in parallel with B               (60 min)
CMAKE_BUILD_PARALLEL_LEVEL=10 bash build_files/android/deps/build.sh llvm

# D — depends on B                                   (17 min)
bash build_files/android/deps/build.sh numpy usd rubberband
```

Running B and C in parallel is safe: they are independent trees and peak memory
stayed around 8 GB of the 31 GB available. Cap LLVM's parallelism with
`CMAKE_BUILD_PARALLEL_LEVEL` so the rest of the machine stays responsive.

When finished there must be **58 prefixes** in `lib/android_arm64`:

```text
abseil alembic aom blosc brotli bzip2 deflate eigen embree expat ffmpeg fmt
freetype fribidi harfbuzz imath jpeg lame libffi llvm lzma materialx
meshoptimizer minizipng ogg opencolorio openexr openimagedenoise openimageio
openjpeg openssl opensubdiv openvdb opus png potrace pugixml pystring python
robinmap rubberband shaderc sqlite sse2neon tbb theora tiff usd vorbis vpx
vulkan webp x264 x265 xml2 yamlcpp zlib zstd
```

`ispc` is deliberately absent from that list: it is a host compiler, needed to
build Open Image Denoise's kernels, and installs into
`android_deps_build/host/ispc` rather than into the target prefix. See
`build_files/android/deps/OPENIMAGEDENOISE.md`.

`build.sh all` walks `ALL_DEPS` in order and skips what already exists, so it
works for resuming after a failure. Careful: the "already built" test only
checks whether the install directory has content; if a build died partway
through its `install` step, delete the prefix before resuming.

### `lite` profile

```bash
bash build_files/android/deps/build.sh \
  zlib zstd deflate imath fmt tbb openexr png pugixml jpeg brotli \
  freetype harfbuzz webp tiff openjpeg expat yamlcpp pystring \
  minizipng opencolorio robinmap openimageio sqlite libffi openssl \
  lzma bzip2 python eigen sse2neon fribidi vulkan_headers \
  meshoptimizer shaderc
```

## 8. Building the APK (full build)

```bash
PATH="$(printf %s "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"
# The host python 3.13 must be on PATH — see section 16.5.
export PATH="/root/blender_android_deps/android_deps_build/work/python-host-install/bin:$PATH"
export BUILD_BASE=/root/blender_android_deps
export ANDROID_HOME=/root/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOST_CC=gcc-15 ANDROID_HOST_CXX=g++-15

# Side-by-side install, so the already tested lite APK is not replaced.
export BLENDER_ANDROID_FLAVOUR=-s24full
export BLENDER_ANDROID_APPLICATION_ID=org.blender.blender.s24full
export BLENDER_ANDROID_DEBUGGABLE=1

cd /root/blender-android-fast
bash build_files/android/build_apk.sh full     # or: lite
```

The script runs three steps:

1. configures and builds `makesdna`, `makesrna`, `datatoc`, `msgfmt` and
   `shader_tool` on the host with the same profile as the target
   (~4 min 30 s for `full`);
2. configures the target with the NDK and builds
   `build_android_full/lib/libblender.so`;
3. packages the APK into
   `android_apk_stage_full-s24full/blender-full-s24full.apk`.

This is the slow path: roughly **25 minutes** end to end. Use it once, then
switch to the fast loop below.

## 9. Fast iteration loop

This is the part that turned this port from unworkable into practical. A full
`build_apk.sh` takes ~25 minutes; the loop below turns an edit to a `.cc` file
into a running, tested APK on the device in **2 to 4 minutes**. Everything here
is reproducible from scratch by following this section alone.

### 9.1 Why it is fast

`fastdeploy.sh` reuses the packaged stage that `build_apk.sh` already produced.
Of the 173 MB APK, only `libblender.so` changes when C++ source is edited: the
62 MB Python/scripts payload, the other 128 native libraries, the resources and
the DEX are all identical. So the script:

1. runs `ninja -C "$BUILD" blender` — an incremental compile and link, which is
   the only genuinely expensive step;
2. copies the fresh `libblender.so` into the stage's `lib/arm64-v8a/`;
3. runs `patchelf --set-soname libblender.so` and `llvm-strip --strip-unneeded`
   on that copy (the loader needs the soname to match the file name, and the
   unstripped library is 1.75 GB);
4. copies `base.apk` — which already holds the payload and resources — to the
   output name, then adds `classes.dex` and the `lib/` tree with `zip`;
5. runs `zipalign -f -p 4` and re-signs with `apksigner`.

No re-zip of the 62 MB payload, no re-running of the code generators, no
reconfiguring of CMake.

**Prerequisite:** `build_apk.sh <config>` must have run once, so
`$STAGE/base.apk` and `$STAGE/lib/arm64-v8a/libblender.so` exist. The script
refuses to run otherwise, with `No packaged stage found`.

### 9.2 The driver script

`/root/ci/fast.sh` wraps `fastdeploy.sh` with the environment the build needs.
Recreate it exactly:

```bash
cat > /root/ci/fast.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
# The Windows PATH makes CMake stall for minutes on the 9p mount (section 16.2).
PATH="$(printf %s "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"
export PATH="/root/blender_android_deps/android_deps_build/work/python-host-install/bin:$PATH"
export BUILD_BASE=/root/blender_android_deps
export ANDROID_HOME=/root/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export ANDROID_HOST_CC=gcc-15 ANDROID_HOST_CXX=g++-15
export BLENDER_ANDROID_FLAVOUR=-s24full
export FASTDEPLOY_NO_INSTALL=1
cd /root/blender-android-fast
time bash build_files/android/fastdeploy.sh full
SCRIPT
chmod +x /root/ci/fast.sh
```

Two variables matter and are easy to get wrong:

- `BLENDER_ANDROID_FLAVOUR` must match the flavour used by `build_apk.sh`.
  Flavours share a build tree but have their own stage directory and output
  name, exactly as `package.sh` lays them out. Without it the script looks for a
  stage a flavoured build never wrote and stops on `No packaged stage found`.
- `FASTDEPLOY_NO_INSTALL=1` stops the script before its install step. Use it.
  The built-in install path is hardcoded to `org.blender.blender` and
  `org.blender.blender/.BlenderActivity`, which is wrong for any flavoured
  build, and in this setup `adb` talks to the device from Windows rather than
  from inside WSL2. Install from the Windows side instead (section 9.3).

### 9.3 The full cycle

The edit is made in `/root/blender-android-fast` (section 5), gets built there,
and the APK is handed to Windows only because `adb` talks to the device from
that side.

```bash
# 1. incremental build + repackage (~2-4 min)
bash /root/ci/fast.sh > /root/logs/fast.log 2>&1
echo "exit=$?"
grep -E "error:|FAILED" /root/logs/fast.log | head

# 2. hand the APK back to Windows
cp /root/blender_android_deps/android_apk_stage_full-s24full/blender-full-s24full.apk \
   /mnt/g/PROGRAMING/BLENDER/blender-android/build/android-apk/blender-full-s24full-diag.apk
```

Then, from Windows:

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$s = '<ADB_SERIAL>'
& $adb -s $s install -r -t 'G:\PROGRAMING\BLENDER\blender-android\build\android-apk\blender-full-s24full-diag.apk'
```

**Do not pipe `fast.sh` into `tail` or `head`.** The exit status of a pipeline is
the last command's, so a failed build reports success and the previous APK gets
copied over as if it were new. Redirect to a log and check `$?` instead. This
already happened once and produced a "successful" deploy of a stale binary.

### 9.4 Runtime launch arguments without rebuilding

`GHOST_AndroidMain.cc` reads whitespace-separated launch arguments from
`<internalDataPath>/blender_args.txt` when that file exists. Nothing is passed
by default beyond `--disable-crash-handler`.

This exists because diagnosing a driver quirk means toggling flags such as
`--debug-gpu-force-workarounds` or `--log` while watching logcat, and rebuilding
and reinstalling a 173 MB APK for each attempt makes that loop useless. With the
file, changing flags costs one `adb shell` and a relaunch:

```powershell
$P = 'org.blender.blender.s24full'
& $adb -s $s shell "echo '--log gpu.* --log-level 3' > /data/local/tmp/args.txt"
& $adb -s $s shell "run-as $P cp /data/local/tmp/args.txt /data/data/$P/files/blender_args.txt"
```

Remove the file to go back to defaults. The arguments actually used are echoed
to logcat at startup as `[BlenderAndroid] argv: ...`, so there is never any
doubt about which set is in effect.

### 9.5 Driving tests on the device

Blender auto-imports every `.py` module in `scripts/startup`, and the extracted
runtime lives in the app's private directory. Because the build is debuggable,
`run-as` can write there. Dropping a module in that directory gives a test
harness that runs inside Blender with no UI automation:

```powershell
$P = 'org.blender.blender.s24full'
& $adb -s $s push probe.py /data/local/tmp/probe.py
& $adb -s $s shell "run-as $P cp /data/local/tmp/probe.py /data/data/$P/files/blender/5.3/scripts/startup/zz_probe.py"
& $adb -s $s shell "run-as $P rm -rf /data/data/$P/files/blender/5.3/scripts/startup/__pycache__"
```

The module defines `register()`, which Blender calls, and schedules the actual
work with `bpy.app.timers.register(fn, first_interval=6.0)` so the window
manager, viewport and GPU resources all exist by the time it runs. Print one
line per step and flush each one: when the process dies, the last line printed
names the step that killed it. `print()` reaches logcat because
`GHOST_AndroidMain.cc` redirects stdout and stderr there.

Read which test to run from a control file rather than editing the module, so
switching tests costs one `echo`:

```python
with open("/data/data/org.blender.blender.s24full/files/blender/androidtest.txt") as fh:
    name = fh.read().strip()
```

**Remove the harness when finished.** A module left in `scripts/startup` runs on
every launch, which looks exactly like a bug in the application — a subsurf
modifier appearing on its own at every startup was traced back to a forgotten
harness.

### 9.6 Classifying the outcome automatically

A hang is only visible if something is waiting on the application: Android
declares an ANR when input goes unconsumed for 10 seconds. Without poking the
window, a hung process looks perfectly healthy to `pidof`. So the test runner
injects taps after the test fires, then classifies:

```powershell
Start-Sleep -Seconds $SettleSeconds        # let the test run
$deadline = (Get-Date).AddSeconds(30)      # then make the window prove it lives
while ((Get-Date) -lt $deadline) {
  & $adb -s $s shell input tap 1200 500 | Out-Null
  Start-Sleep -Seconds 3
}

$procId = (& $adb -s $s shell pidof $P 2>$null)
$log = & $adb -s $s logcat -d -v brief
if     ($log | Select-String 'Fatal signal|SIGSEGV') { "CRASHED" }
elseif (-not $procId)                                { "PROCESS GONE" }
elseif ($log | Select-String "ANR in $P")            { "HUNG" }
else                                                 { "ALIVE AND RESPONSIVE" }
```

Distinguishing these four outcomes matters more than it sounds. A `SIGKILL` with
no crash log is the system reclaiming memory, not a bug in the code; an ANR with
an idle CPU is a blocked thread, not slow code. Treating them alike sends the
investigation in the wrong direction.

### 9.7 Symbolicating a native crash

APK libraries are stripped, but the build tree keeps the unstripped
`libblender.so`. `llvm-symbolizer` needs DWARF that a Release build does not
carry, so resolve addresses against the symbol table instead:

```bash
NDK=/root/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin
SO=/root/blender_android_deps/build_android_full/lib/libblender.so
"$NDK/llvm-nm" --numeric-sort --defined-only -C "$SO" \
  | awk '$2=="t"||$2=="T"||$2=="w"||$2=="W"' > /root/logs/syms.txt

# then, for each "pc <address>" in the logcat backtrace:
awk -v target=$((16#043aa190)) \
  '{a=strtonum("0x"$1); if (a<=target) {n=$0; sub(/^[0-9a-f]+ [a-zA-Z] /,"",n); last=n} else {print last; exit}}' \
  /root/logs/syms.txt
```

This resolves to the nearest preceding symbol, which is accurate for ordinary
functions and can be wrong for static functions and thunks. If a frame looks
impossible — a constructor calling a thread entry point, say — distrust that
frame rather than the analysis, and rebuild with `-g` if the answer matters.

### 9.8 Testing shader changes with no rebuild at all

Blender caches compiled SPIR-V on the device under
`/storage/emulated/0/Android/data/<pkg>/files/blender/vk-spirv-cache-vk1x/`, as
`<hash>.spv` plus a `<hash>.sidecar.bin` holding a single little-endian
`uint64` — the size of the `.spv`. The loader validates only that size, not the
content.

That makes the cache a shader laboratory: replace a `.spv` with a modified
module, regenerate the sidecar with the new size, relaunch, and Blender uses it.
This is how the Adreno compute-pipeline failure was narrowed down without ever
rebuilding Blender.

```bash
spirv-opt --strip-debug in.spv -o out.spv
python3 -c "import struct,sys; open(sys.argv[1],'wb').write(struct.pack('<Q', int(sys.argv[2])))" \
  out.sidecar.bin "$(stat -c %s out.spv)"
```

Always validate the mapping before trusting the results. Substituting one
module with a trivial no-op compute shader and confirming that exactly the
expected pipeline stops failing proves both that the hash-to-shader mapping is
right and that the modified module is really being loaded. Skipping that check
produced two rounds of conclusions drawn from files that were never read.

### 9.9 What the loop cannot do

`fastdeploy.sh` only replaces `libblender.so`. Run the full `build_apk.sh` again
whenever:

- Python scripts, `release/datafiles` or any other payload content changes;
- the manifest, resources or `BlenderActivity.java` change;
- a feature toggle changes, since the host code generators must be rebuilt with
  the same profile as the target;
- a new dependency is linked, since the transitive `.so` collection runs in
  `package.sh`.

## 10. Verifying the APK before installing

```bash
BT=/root/android-sdk/build-tools/35.0.1
APK=/root/blender_android_deps/android_apk_stage_full-s24full/blender-full-s24full.apk

"$BT/apksigner" verify --print-certs "$APK"       # signature
unzip -t "$APK" >/dev/null && echo "ZIP OK"       # integrity
unzip -l "$APK" | grep -c "lib/arm64-v8a/.*\.so"  # should be 129 for full
```

Confirm the heavy features actually made it in, rather than trusting
`CMakeCache.txt`:

```bash
SO=/root/blender_android_deps/build_android_full/lib/libblender.so
NDK=/root/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin

"$NDK/llvm-nm" -C --defined-only "$SO" | grep -c "ccl::"   # Cycles: ~10,774
"$NDK/llvm-readelf" -d "$SO" | grep NEEDED                 # USD, VDB, embree, avcodec…
```

An `ON` flag in the cache only proves CMake found the library. Only symbols and
`NEEDED` entries prove it was actually linked — that is how LLVM and Rubberband
were found to be present but unused.

## 11. Installing and diagnosing

From Windows PowerShell:

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$serial = '<DEVICE_ADB_SERIAL>'
$apk = 'G:\PROGRAMING\BLENDER\blender-android\build\android-apk\Blender-5.3.0-Alpha-Android-arm64-S24Ultra-FULL-20260820.apk'

& $adb -s $serial install -r -t $apk
& $adb -s $serial shell appops set org.blender.blender.s24full MANAGE_EXTERNAL_STORAGE allow
& $adb -s $serial logcat -c
& $adb -s $serial shell am start -n org.blender.blender.s24full/org.blender.blender.BlenderActivity
```

Useful checks:

```powershell
& $adb -s $serial shell pidof org.blender.blender.s24full
& $adb -s $serial logcat -d --pid=<PID> -v brief
& $adb -s $serial shell dumpsys activity lastanr
```

Expected signs of a healthy startup:

```text
WM_init: native window and GPU context created
WM_init: startup file loaded
WM_init: GPU UI resources ready
WM_init: Python ready
WM_init: complete
creator: event loop ready
```

**The screen must be unlocked and awake during the test.** The first run extracts
~62 MB of payload; if the device blanks the screen during that window, the
activity is stopped before native initialization and logcat shows only
`Not drawing due to not visible` and `onDisplayChanged ... newDisplayState=1`,
with no `WM_init` marker at all. That is not a build failure. Keep the screen on
(`Settings > Display > Screen timeout`) or wake it with
`adb shell input keyevent KEYCODE_WAKEUP` before relaunching.

## 12. Modified files and what each group does

### Build, dependencies and packaging

- `build_files/android/android_features_{common,full,lite}.cmake`: profiles.
- `build_files/android/env.sh`: Linux/WSL detection, NDK, JDK, host compiler and
  `LD_LIBRARY_PATH` for the host binaries.
- `build_files/android/deps/build.sh`: cross-compilation of the dependencies,
  Linux parallelism, host Python and AArch64 verification.
- `build_files/android/build_apk.sh`: incrementally rebuilds the host tools with
  the same profile as the target; mandatory for RNA with Python.
- `build_files/android/configure.sh`: Android toolchain configuration.
- `build_files/android/fastdeploy.sh`: fast `libblender.so` swap when the payload
  is unchanged (section 9).
- `build_files/android/apk/package.sh`: transitive `.so` collection, Python and
  script runtime, Cycles add-on, unversioned ELF names, strip, DEX, resources,
  alignment and signing.
- `build_files/android/apk/app/src/main/AndroidManifest.xml`: name, version,
  icon, orientation, Vulkan and storage permissions.
- `build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java`:
  versioned runtime extraction, immersive mode, file access and the soft
  keyboard bridge.
- `build_files/cmake/platform/platform_android.cmake`: dependency prefixes,
  imported host tools and platform-invariant options.

### Window and input (GHOST)

- `intern/ghost/intern/GHOST_AndroidMain.cc`: `android_main`, logcat redirection,
  lifecycle, input, per-frame loop and the `blender_args.txt` reader.
- `intern/ghost/intern/GHOST_AndroidMemoryTier.hh`: render scale and logical DPI;
  the current UI default is 160 DPI.
- `intern/ghost/intern/GHOST_SystemAndroid.{cc,hh}`: physical mouse, buttons,
  wheel, stylus/S Pen, touch, gestures, clipboard, keyboard and GHOST events.

### Startup, Python, Vulkan and viewport

- `source/creator/creator.cc`: Android entry point and handing over the
  `bContext`.
- `source/blender/windowmanager/intern/wm_init_exit.cc`: Android startup, GPU,
  startup file and Python; includes the diagnostic markers and the GPU
  subdivision probe.
- `source/blender/python/intern/bpy_interface.cc`: diagnostics for the embedded
  Python phases.
- `source/blender/gpu/vulkan/vk_shader_compiler.cc`: SPIR-V target version and
  the on-disk SPIR-V cache.
- `source/blender/gpu/vulkan/vk_backend.cc`: Qualcomm/Android compatibility and
  the Turnip option.
- `source/blender/gpu/vulkan/vk_pipeline_pool.cc`: pipeline creation, including
  the fallback for pipelines the driver refuses.
- `source/blender/draw/intern/draw_manager.cc`: Android fallback for draw paths
  that misbehave on the Adreno 750.
- `source/blender/draw/intern/draw_command.cc`: CPU generation of indirect
  commands on Android.
- `source/blender/editors/interface/interface_handlers.cc`: interface tweaks.
- `source/blender/asset_system/intern/disk_file_hash_service.cc`: build fixes
  with Python enabled.

## 13. Data and secret safety in WSL2

WSL2 directories belonging to this project:

```text
/root/blender-android-fast
/root/blender_android_deps
/root/android-sdk
/root/ci
/root/logs
```

Never run a recursive delete on `/root`, `/home`, `/mnt/g` or the distribution
root. Resolve and **check** the absolute path before any removal.

Keep out of the repository: ADB keys (`~/.android/adbkey*`), SSH keys,
Git/GitHub tokens, `gradle.properties` with tokens, release keystores, `.env`,
certificates and WSL2 `.vhdx` exports.

```bash
chmod 700 /root/.android-signing
chmod 600 /root/.android-signing/*.jks
```

`android-debug.keystore` uses the standard public credentials `android/android`;
it is for testing only and never for publishing. A release build should receive
the keystore path through an environment variable or an ignored local file,
without copying the key into the checkout.

A `wsl --export` contains everything in the distribution, keys and tokens
included. Store exports only on an encrypted volume.

Logs and ANR reports can contain local paths and device identifiers. Keep them
out of Git and review them before sharing.

## 14. Safe cleanup

Can be removed and regenerated cheaply:

- `android_apk_stage_*`;
- `build_android_{full,lite}`;
- `build_host_tools_{full,lite}`;
- `android_deps_build/work` (the build trees; ~30 GB);
- local APKs and screenshots;
- `.ninja_log`, `.ninja_deps`, `CMakeCache.txt` and `CMakeFiles`.

Expensive, but regenerable (~2 h 30 min in total):

- `/root/blender_android_deps/lib/android_arm64`.

Do not remove while work continues:

- `/root/blender-android-fast`;
- `/root/blender_android_deps/lib/android_arm64`;
- `/root/blender_android_deps/android_deps_build/downloads`;
- `/root/blender_android_deps/android_deps_build/work/python-host-install`;
- the `G:\PROGRAMING\BLENDER\blender-android` repository.

## 15. Reference timings

Measured on 16 vCPUs / 31 GB / SATA SSD, from scratch:

| Step | Time |
| --- | --- |
| Provisioning SDK + NDK | ~6 min |
| `rsync` of the repository (3.5 GB over 9p) | ~4 min |
| Deps stage A (42 packages) | 38 min 32 s |
| Deps stage B (Python, OpenVDB, codecs, FFmpeg) | 33 min 07 s |
| Deps LLVM (in parallel with B) | 60 min 33 s |
| Deps stage D (NumPy, USD, Rubberband) | 17 min 13 s |
| Host tools, `full` | 4 min 31 s |
| `libblender.so` + packaging | ~25 min |
| **Practical total** | **~3 h** |
| **One `fastdeploy` cycle (section 9)** | **2–4 min** |

## 16. Known pitfalls — do not repeat

### 16.1 Moving the WSL2 distribution (one distribution was already lost here)

`wsl --manage <distro> --move <destination>` **requires an elevated terminal**
and the destination directory must exist and be empty. Without elevation the
operation fails with `E_ACCESSDENIED`, but it **can fail after it has already
started moving data**: the original VHDX is removed from the source while the
WSL registry still points at the old path.

That intermediate state is exactly what destroyed the previous distribution: the
partially filled destination was deleted with `Remove-Item -Recurse -Force`
without inspecting its contents first, taking the ~15 GB of VHDX already copied
with it. `Remove-Item -Force` does not use the Recycle Bin, and on an SSD with
TRIM there is no recovery.

Rules:

1. **Never** delete a WSL destination directory without listing its contents
   first (`Get-ChildItem -Recurse`) and checking the size.
2. Before and after any move, verify where the VHDX is:
   ```powershell
   Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss |
     ForEach-Object { $p = Get-ItemProperty $_.PSPath
       if ($p.DistributionName) { "$($p.DistributionName) => $($p.BasePath)" } }
   Get-ChildItem 'G:\WSL' -Recurse -Filter '*.vhdx' |
     Select-Object FullName, @{n='GB';e={[math]::Round($_.Length/1GB,2)}}
   ```
3. If the registered `BasePath` does not contain `ext4.vhdx`, the distribution is
   broken — stop and investigate, do not delete anything.
4. An alternative with no elevation and no destructive intermediate state:
   `wsl --export` to a `.tar` on another volume, check the `.tar` size,
   `wsl --unregister`, then `wsl --import` at the destination.
5. For a new distribution, pick the destination at install time and avoid the
   move entirely:
   ```powershell
   wsl --install Ubuntu-26.04 --location 'G:\WSL\Ubuntu-26.04' --no-launch
   ```
   `--location` and `--no-launch` do not require elevation, and the distribution
   starts with `root` as the default user, which is what these scripts expect.

What is lost with the distribution: dependencies, SDK/NDK and build trees — all
regenerable in ~3 h — **and any uncommitted work in
`/root/blender-android-fast`**, which since section 5 is the working copy rather
than a disposable mirror. What is **not** lost: anything already pushed to
`origin`, plus the Windows clone, which keeps the history offline.

So the rule changed with the layout: **commit and push before touching the
environment.** A commit alone no longer protects the work, because the commit
would live in the distribution that is about to be removed.

### 16.2 The Windows PATH stalls CMake inside WSL

WSL2 appends the entire Windows `PATH` to the Linux `PATH` (40 directories in
this environment). Every CMake `find_program()` walks those directories over the
9p mount, and a single `configure` can sit for **more than 22 minutes** printing
nothing.

The exact symptom: the `cmake` process sits in state `D` while the machine is
idle.

```bash
awk '{print $3}' /proc/<pid>/stat   # D = uninterruptible sleep
cat /proc/<pid>/wchan               # p9_client_rpc  <-- this is it
```

Permanent fix (takes effect on the next distribution start):

```bash
printf '[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf
```

Immediate fix, at the top of every build script:

```bash
PATH="$(printf %s "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"
export PATH
```

With the fix, OpenVDB's `configure` went from "over 22 minutes, stuck" to a few
seconds.

### 16.3 `lib/linux_x64` arrives from Windows with broken symlinks

The Windows checkout has no symlink support, so Git materializes every symlink
as a small regular file containing the link target. `rsync` copies that
faithfully and the loader then fails to run the host generators:

```text
makesdna: error while loading shared libraries:
  .../lib/linux_x64/tbb/lib/libtbbmalloc_proxy.so.2: file too short
```

116 files are in that state. The `lite` profile does not hit them because it has
`WITH_TBB=OFF`; `full` hits them on the very first `makesdna`.

`/root/ci/fix_symlinks.sh` converts them back. The criterion is deliberately
conservative: a regular file under 200 bytes, with no newline, whose contents
resolve to an existing path relative to its own directory and whose size matches
the target string exactly.

This only bites a `lib/linux_x64` that came from a Windows checkout, which is
how the current tree was seeded. It no longer happens on its own: `lib/` is
gitignored and is now fetched inside WSL2 with
`git submodule update --init lib/linux_x64`, where Git creates real symlinks.
Run the script only if the "file too short" error above actually appears.

### 16.4 Host Python: `ensurepip` is mandatory

`build_python` builds a host CPython 3.13 before cross-compiling. On macOS,
`host_python()` found Homebrew's Python, which already has `pip`; on Linux this
locally built interpreter is the only 3.13 available. Since `build_numpy` runs
`python -m venv` and installs `cython` and `meson-python` into it, the host
stage needs `--with-ensurepip=install` — with `--without-ensurepip` the `venv`
fails and NumPy never builds.

The cross-compile stage keeps `--without-ensurepip`, as it should.

### 16.5 CMake picks the wrong Python for the build scripts

`platform_android.cmake` looks for a host interpreter to run `discover_nodes.py`
and the other generation scripts. Every dependency prefix is on
`CMAKE_PREFIX_PATH`, and one of them — `${LIBDIR}/python/bin` — holds the
**Android** interpreter. `NO_CMAKE_FIND_ROOT_PATH` alone does not exclude it, and
the build dies with:

```text
/bin/sh: 1: .../lib/android_arm64/python/bin/python3.13: Exec format error
```

The search is now restricted to the host `PATH`:

```cmake
find_program(HOST_PYTHON_EXECUTABLE NAMES python3.13 python3 python
  NO_CMAKE_FIND_ROOT_PATH NO_CMAKE_PATH NO_CMAKE_SYSTEM_PATH
  NO_CMAKE_ENVIRONMENT_PATH NO_PACKAGE_ROOT_PATH)
```

That is also why section 8 puts `python-host-install/bin` on `PATH`: so the build
interpreter matches the target's version.

### 16.6 Do not edit a shell script while it is running

`deps.sh` was rewritten while the LLVM stage was still running. `bash` re-reads
the file from the byte offset it had reached, and started executing fragments of
the new content:

```text
/root/ci/deps.sh: line 12: port: command not found
```

The damage was nil in that case — the real work had already finished — but the
same accident in the middle of a step produces arbitrary behavior. To edit a
script that is in use: copy it to a new name and use the new one, or wait for
the step to finish.

### 16.7 Do not edit `CMakeCache.txt` by hand

To force Python to be rediscovered, two entries were deleted from the cache with
`sed`. The file became inconsistent and the next run aborted with
`Parse error in cache file ... on line 398`.

To invalidate a variable, use CMake's own tools:

```bash
cmake -U HOST_PYTHON_EXECUTABLE -U PYTHON_EXECUTABLE -S <src> -B <build>
```

Or, when the cost is acceptable, delete the whole build directory.

### 16.8 Background processes do not survive the end of a `wsl.exe` session

`wsl.exe -d <distro> -- bash -c 'nohup ... &'` does **not** leave the process
running: when the session ends WSL tears down the child processes and not even
the log file is created. Long builds must keep `wsl.exe` alive for the whole
duration (for example, as a background process on the Windows side) or be
launched under a service manager inside the distribution.

### 16.9 Do not judge a build by a piped command's exit status

```bash
bash /root/ci/fast.sh 2>&1 | tail -5   # WRONG: reports tail's status
```

A pipeline's exit status is the last command's, so a failed build looks
successful and whatever ran next — copying the APK, installing it — proceeds
with a stale binary. Redirect to a log file and test `$?`, or set
`set -o pipefail`.

### 16.10 Why an earlier APK had an empty interface

Historical sequence, kept because it explains decisions in `build_apk.sh`:

1. without Python, Blender rendered the scene but registered no menus, panels or
   headers;
2. once Python was enabled, a stale extraction marker prevented `encodings` from
   being copied, causing `Failed to import encodings`;
3. the marker was versioned as `py313-ui1`, forcing a fresh extraction;
4. the host tools had still been built with `WITH_PYTHON=OFF`, so the generated
   RNA registered no `Operator` or `Gizmo`;
5. `build_apk.sh` began reconfiguring the host generators with the same profile
   as the target;
6. the next APK initialized Python and showed the complete interface.

## 17. Next technical points

1. **Viewport performance with heavy geometry.** Shadows dominate the frame on a
   subdivided 290k vertex scene, costing several times the rest of the draw, and
   the measurements are noisy enough that no shadow tuning has been justified
   yet. This needs per-pass instrumentation rather than whole-frame benchmarks.
2. **Gizmo input ANR**, inherited from `lite` and never re-tested since the
   compute pipeline failures were fixed. It may well have been the same root
   cause; confirm before investigating further. Do not revert Python, DPI or the
   RNA work — those steps are proven.
3. ~~**Cycles on the device**: measure render time and memory for the default
   scene.~~ Measured on a Galaxy S24 Ultra: the default cube renders in 26.1 s
   on CPU + embree at the adaptive threshold, `Mem:151M, Peak:151M` as reported
   by Blender, while the process peaks near 1.8 GB during the Open Image Denoise
   pass and settles back to ~740 MB. The 1.8 GB spike, not the wall time, is the
   figure that constrains a lower-memory device.
4. **OSL**, which would put the already-compiled LLVM to real use. It needs a
   host clang matching LLVM 20 to generate the shader bitcode.

## Required render gate for full releases

Before publishing, use `python3 build_files/android/build.py full --release
--render-reference /path/to/official-render-reference -s DEVICE_SERIAL`.
Publish only an APK and matching `.render-check.json` from
`$BUILD_BASE/apk/releases`. The command repackages and tests the exact signed
candidate, including EEVEE in motion; incomplete validation fails.
See [tests/README.md](build_files/android/tests/README.md) for reference generation,
prerequisites, individual APK checks and the known-bad control.
