#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build, package and deploy Blender for Android.

Wraps the shell scripts in this directory so the four usable builds are one
command each:

    ./build.py lite                     # lite APK
    ./build.py full --install --run     # full APK onto the connected device
    ./build.py lite --validation        # + Khronos validation layer
    ./build.py --enable-turnip          # run on Mesa Turnip (no rebuild)

Run with --help for the rest.
"""

from __future__ import annotations

import argparse
import datetime
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
# What makes a directory the build base rather than an empty path that happens to
# exist: the cross-compiled dependency prefix cmake is pointed at.
DEPS_MARKER = Path("lib") / "android_arm64"

# Where the shell scripts look when BUILD_BASE is unset. Each of them computes this
# fallback on its own, so if this process guesses differently the two halves build
# against different trees.
DEFAULT_BUILD_BASE = REPO_ROOT.parent / "blender_build_android"

# Checked in order when BUILD_BASE is unset, first one holding the dependency prefix
# wins. Guessing wrong used to surface two minutes later as a cmake error about a
# missing LIBDIR, with the build already half-configured.
BUILD_BASE_CANDIDATES = (
    DEFAULT_BUILD_BASE,
    REPO_ROOT.parent / "blender_android_deps",
    Path.home() / "blender_android_deps",
)


def resolve_build_base(explicit: str | None = None) -> Path:
    """Settle on one build base and put it in the environment.

    Exporting is the point: every shell script downstream reads BUILD_BASE and has
    its own fallback, so making this process authoritative is what keeps them from
    disagreeing.
    """
    if explicit:
        base = Path(explicit).expanduser()
    elif os.environ.get("BUILD_BASE"):
        base = Path(os.environ["BUILD_BASE"]).expanduser()
    else:
        base = next(
            (c for c in BUILD_BASE_CANDIDATES if (c / DEPS_MARKER).is_dir()),
            DEFAULT_BUILD_BASE,
        )
    base = base.resolve()
    os.environ["BUILD_BASE"] = str(base)
    return base


BUILD_BASE = resolve_build_base()


def require_deps() -> None:
    """Stop before configuring if the dependencies are not where we are looking."""
    if (BUILD_BASE / DEPS_MARKER).is_dir():
        return
    sys.exit(
        "\n".join([
            f"error: no Android dependency prefix under {BUILD_BASE}",
            f"  expected: {BUILD_BASE / DEPS_MARKER}",
            "",
            "Point BUILD_BASE at the directory that holds them, or pass --build-base:",
            "    BUILD_BASE=/path/to/deps build_files/android/build.py full",
            "",
            "If they have never been cross-compiled:",
            "    build_files/android/deps/build.sh",
        ])
    )

# Every build lands here under its own timestamp, so a device that misbehaves
# can be compared against the APK that came before it. The stage APK is
# overwritten by the next build; this one is not.
APK_ARCHIVE = BUILD_BASE / "apk"

PACKAGE = "org.blender.blender"
ACTIVITY = f"{PACKAGE}/.BlenderActivity"

# Pinned so a validation run is reproducible; bump deliberately.
VVL_VERSION = "1.4.357.0"
VVL_URL = (
    "https://github.com/KhronosGroup/Vulkan-ValidationLayers/releases/download/"
    f"vulkan-sdk-{VVL_VERSION}/android-binaries-{VVL_VERSION}.zip"
)
VVL_SO = "libVkLayer_khronos_validation.so"

# Caches that survive reinstall and will happily serve stale shaders.
DEVICE_CACHES = (
    "vk-spirv-cache-vk11",
    "vk-spirv-cache-vk12",
    "vk-pipeline-cache",
)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+ " + " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, check=True, **kwargs)


def tool_env() -> dict[str, str]:
    """env.sh settings merged over the caller's environment.

    zipalign and apksigner are wrapper scripts that need JAVA_HOME and the SDK
    on PATH, so they cannot inherit a bare environment.
    """
    merged = dict(os.environ)
    merged.update(env_from_env_sh())
    return merged


def sh(script: str) -> None:
    """Run a snippet through the login shell so env.sh resolves the SDK."""
    run(["bash", "-lc", script])


def env_from_env_sh() -> dict[str, str]:
    """env.sh owns the SDK/NDK locations; read them rather than guessing."""
    out = subprocess.run(
        ["bash", "-c", f"unset ANDROID_HOME; source '{SCRIPT_DIR / 'env.sh'}' >/dev/null && env"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return dict(
        line.split("=", 1) for line in out.splitlines() if "=" in line
    )


def adb(args: list[str], serial: str | None, **kwargs) -> subprocess.CompletedProcess:
    cmd = ["adb"] + (["-s", serial] if serial else []) + args
    return run(cmd, **kwargs)


def flavour(turnip: bool) -> str:
    return "-turnip" if turnip else ""


def stage_dir(config: str, turnip: bool = False) -> Path:
    return BUILD_BASE / f"android_apk_stage_{config}{flavour(turnip)}"


def apk_path(config: str, turnip: bool = False) -> Path:
    return stage_dir(config, turnip) / f"blender-{config}{flavour(turnip)}.apk"


def archive_apk(config: str, turnip: bool, keep: int) -> Path | None:
    """Copy the freshly built APK into APK_ARCHIVE under a timestamped name.

    The stage APK always has the same path, which makes it impossible to tell
    two builds apart after the fact -- and impossible to go back to the one that
    worked. `<config>-latest.apk` is a hard link rather than a symlink so it
    reads as an ordinary file through the wsl.localhost share, which is where
    adb installs from on the Windows side.
    """
    src = apk_path(config, turnip)
    if not src.exists():
        print(f"[archive] no APK at {src}, nothing to keep")
        return None

    APK_ARCHIVE.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    stem = f"blender-{config}{flavour(turnip)}"
    dest = APK_ARCHIVE / f"{stem}-{stamp}.apk"
    shutil.copy2(src, dest)

    latest = APK_ARCHIVE / f"{stem}-latest.apk"
    latest.unlink(missing_ok=True)
    try:
        os.link(dest, latest)
    except OSError:
        shutil.copy2(dest, latest)

    size_mb = dest.stat().st_size / (1024 * 1024)
    print(f"[archive] {dest}  ({size_mb:.0f} MB)")
    print(f"[archive] latest -> {latest}")

    if keep > 0:
        builds = sorted(
            (p for p in APK_ARCHIVE.glob(f"{stem}-20*.apk")),
            key=lambda p: p.name,
            reverse=True,
        )
        for old_apk in builds[keep:]:
            old_apk.unlink()
            print(f"[archive] removed {old_apk.name} (over --keep {keep})")

    return dest


def clean(config: str) -> None:
    for path in (
        BUILD_BASE / f"build_android_{config}",
        BUILD_BASE / f"build_host_tools_{config}",
        stage_dir(config),
    ):
        if path.exists():
            print(f"removing {path}")
            shutil.rmtree(path)


def pending_edges(config: str) -> int:
    """How much ninja thinks is stale, so a surprise full rebuild is visible."""
    build_dir = BUILD_BASE / f"build_android_{config}"
    if not (build_dir / "build.ninja").exists():
        return -1
    try:
        out = subprocess.run(["bash", "-lc", f"ninja -C '{build_dir}' -n blender"],
                             check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError:
        return -1
    return sum(1 for line in out.splitlines() if "Building" in line or "Linking" in line)


def build(config: str, repackage: bool = False, debuggable: bool = False,
          turnip: bool = False, reconfigure: bool = False) -> None:
    """Recompile, and repackage only as much as the change requires.

    Three paths, cheapest first. Only libblender.so usually changes, so reusing
    the staged runtime payload saves rebuilding a 61 MB asset zip and
    re-gathering every native library. Debuggability and the bundled layer live
    in the APK, not in the compiled code, so they need repackaging but never a
    reconfigure -- forcing one used to turn a flag change into a full rebuild.
    """
    require_deps()
    stage = stage_dir(config, turnip)
    build_dir = BUILD_BASE / f"build_android_{config}"
    configured = (build_dir / "build.ninja").exists()
    staged = (stage / "base.apk").exists() and (stage / "lib/arm64-v8a/libblender.so").exists()
    env = "BLENDER_ANDROID_DEBUGGABLE=1 " if debuggable else ""
    if turnip:
        # fastdeploy has no notion of flavours, so a Turnip build always repackages.
        env += f"BLENDER_ANDROID_TURNIP=1 BLENDER_ANDROID_FLAVOUR={flavour(True)} "
        repackage = True

    stale = pending_edges(config)
    if stale >= 0:
        print(f"[build] {stale} ninja edge(s) stale")
        if stale > 500:
            print(f"[build] WARNING: that is a large rebuild for an incremental change. "
                  f"A corrupt {build_dir}/.ninja_deps forces this; delete it to reset.")

    if reconfigure or not configured:
        print("[build] path: full (configure + compile + package)")
        sh(f"{env}'{SCRIPT_DIR / 'build_apk.sh'}' {config}")
    elif repackage or not staged:
        print("[build] path: compile + repackage (no reconfigure)")
        # env.sh, not just ninja: the host code generators run during this build
        # and need it to find their libraries.
        sh(f"source '{SCRIPT_DIR / 'env.sh'}' >/dev/null && ninja -C '{build_dir}' blender")
        sh(f"{env}BLENDER_ANDROID_CONFIG={config} BUILD='{build_dir}' "
           f"bash '{SCRIPT_DIR / 'apk' / 'package.sh'}'")
    else:
        print("[build] path: fast (compile + swap libblender.so)")
        # fastdeploy installs and launches at the end; build.py owns that.
        sh(f"{env}FASTDEPLOY_NO_INSTALL=1 '{SCRIPT_DIR / 'fastdeploy.sh'}' {config}")


def fetch_validation_layer() -> Path:
    """Return a local copy of the arm64 validation layer, downloading once."""
    cache = BUILD_BASE / "validation-layers" / VVL_VERSION
    layer = cache / VVL_SO
    if layer.exists():
        return layer

    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "android-binaries.zip"
    print(f"downloading {VVL_URL}")
    urllib.request.urlretrieve(VVL_URL, archive)
    with zipfile.ZipFile(archive) as zf:
        member = next(
            name for name in zf.namelist() if name.endswith(f"arm64-v8a/{VVL_SO}")
        )
        with zf.open(member) as src, open(layer, "wb") as dst:
            shutil.copyfileobj(src, dst)
    archive.unlink()
    print(f"validation layer -> {layer}")
    return layer


def inject_validation_layer(config: str) -> None:
    """Add the layer to an already-built APK and re-sign it.

    package.sh wipes its staging directory on entry, so the layer cannot be
    staged beforehand: it has to go in afterwards.
    """
    env = tool_env()
    build_tools = Path(env["ANDROID_HOME"]) / "build-tools" / "35.0.1"
    keystore = BUILD_BASE / "android-debug.keystore"
    stage = stage_dir(config)
    apk = apk_path(config)

    shutil.copy2(fetch_validation_layer(), stage / "lib" / "arm64-v8a" / VVL_SO)
    run(["zip", "-q", str(apk), f"lib/arm64-v8a/{VVL_SO}"], cwd=stage)

    aligned = stage / "aligned.apk"
    run([str(build_tools / "zipalign"), "-f", "-p", "4", str(apk), str(aligned)], env=env)
    aligned.replace(apk)
    run([
        str(build_tools / "apksigner"), "sign",
        "--ks", str(keystore),
        "--ks-pass", "pass:android",
        "--key-pass", "pass:android",
        str(apk),
    ], env=env)
    print("validation layer bundled; enable it with --enable-validation-layers")


def set_validation_layers(enabled: bool, serial: str | None) -> None:
    settings = {
        "enable_gpu_debug_layers": "1" if enabled else "0",
        "gpu_debug_app": PACKAGE if enabled else "null",
        "gpu_debug_layers": "VK_LAYER_KHRONOS_validation" if enabled else "null",
    }
    for key, value in settings.items():
        adb(["shell", "settings", "put", "global", key, value], serial)
    print(f"validation layers {'enabled' if enabled else 'disabled'}")


def set_property(name: str, value: str, serial: str | None) -> None:
    adb(["shell", "setprop", name, value], serial)
    print(f"{name} = {value}")


def clear_caches(serial: str | None) -> None:
    base = f"/sdcard/Android/data/{PACKAGE}/files/blender"
    adb(["shell", "rm", "-rf"] + [f"{base}/{name}" for name in DEVICE_CACHES], serial)
    print("shader and pipeline caches cleared")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("config", nargs="?", choices=("lite", "full"),
                        help="feature set to build; omit for device-only actions")
    parser.add_argument("--clean", action="store_true",
                        help="wipe this config's build trees first")
    parser.add_argument("--reconfigure", action="store_true",
                        help="re-apply the feature flags (android_features_*.cmake) before "
                             "building; needed after changing a WITH_* option, and much "
                             "cheaper than --clean because objects are kept")
    parser.add_argument("--repackage", action="store_true",
                        help="rebuild the runtime payload too; needed when scripts, "
                             "datafiles or the dependency set change")
    parser.add_argument("--release", action="store_true",
                        help="full release: repackage, test Cycles and live EEVEE on --serial, "
                             "then promote only a passing APK into apk/releases")
    parser.add_argument("--render-reference", type=Path, metavar="DIR",
                        help="official desktop reference from tests/create_render_reference.py")
    parser.add_argument("--validation", action="store_true",
                        help="bundle the Khronos validation layer into the APK; implies "
                             "--debuggable, which the layer loader requires")
    parser.add_argument("--debuggable", action="store_true",
                        help="mark the APK debuggable; never do this for a release")
    parser.add_argument("--keep", type=int, default=10, metavar="N",
                        help="timestamped APKs to keep in the archive (0 = keep all)")
    parser.add_argument("--no-archive", action="store_true",
                        help="do not copy the APK into the archive")
    parser.add_argument("--install", action="store_true", help="adb install the APK")
    parser.add_argument("--run", action="store_true", help="launch after installing")
    parser.add_argument("--clear-caches", action="store_true",
                        help="drop the on-device shader and pipeline caches")
    parser.add_argument("--enable-validation-layers", action="store_true")
    parser.add_argument("--disable-validation-layers", action="store_true")
    parser.add_argument("--turnip", action="store_true",
                        help="bundle Mesa Turnip in the APK; its presence is what "
                             "selects the driver at runtime")
    parser.add_argument("--enable-turnip", action="store_true",
                        help="run on Mesa Turnip instead of the vendor driver")
    parser.add_argument("--disable-turnip", action="store_true")
    parser.add_argument("--verbose-log", action="store_true",
                        help="per-frame Vulkan tracing (debug.blender.log)")
    parser.add_argument("--build-base", metavar="DIR",
                        help="directory holding the dependency prefix and build trees "
                             "(default: $BUILD_BASE, else autodetected)")
    parser.add_argument("-s", "--serial", help="adb device serial")
    args = parser.parse_args()

    if args.render_reference and not args.release:
        parser.error("--render-reference requires --release; ordinary builds are not validated")

    if args.release:
        if args.config != "full" or not args.serial or not args.render_reference:
            parser.error("--release requires full, --serial and --render-reference")
        if (args.debuggable or args.validation or args.no_archive or args.install or args.run
                or args.clear_caches or args.enable_validation_layers or args.disable_validation_layers
                or args.enable_turnip or args.disable_turnip or args.verbose_log):
            parser.error("--release owns installation/validation; do not combine debug/device actions")
        sys.path.insert(0, str(SCRIPT_DIR / "tests"))
        from run_render_regressions import preflight
        preflight(args.render_reference, args.serial)

    if args.build_base:
        global BUILD_BASE, APK_ARCHIVE
        BUILD_BASE = resolve_build_base(args.build_base)
        APK_ARCHIVE = BUILD_BASE / "apk"

    if args.config:
        if args.clean:
            clean(args.config)
        # A validation build has to be repackaged: base.apk carries the manifest.
        debuggable = args.validation or args.debuggable
        build(args.config,
              repackage=args.repackage or args.clean or debuggable or args.release,
              debuggable=debuggable,
              turnip=args.turnip,
              reconfigure=args.reconfigure)
        if args.validation:
            inject_validation_layer(args.config)
        print(f"APK: {apk_path(args.config, args.turnip)}")
        if args.release:
            from release_validation import validate_release
            validate_release(apk_path(args.config, args.turnip), args.render_reference,
                             BUILD_BASE, args.serial)
        elif not args.no_archive:
            archive_apk(args.config, args.turnip, args.keep)

    if args.install:
        if not args.config:
            parser.error("--install needs a config")
        adb(["install", "-r", str(apk_path(args.config))], args.serial)

    if args.clear_caches:
        clear_caches(args.serial)
    if args.enable_validation_layers:
        set_validation_layers(True, args.serial)
    if args.disable_validation_layers:
        set_validation_layers(False, args.serial)
    if args.enable_turnip:
        set_property("debug.blender.turnip", "1", args.serial)
    if args.disable_turnip:
        set_property("debug.blender.turnip", "0", args.serial)
    if args.verbose_log:
        set_property("debug.blender.log", "1", args.serial)

    if args.run:
        adb(["shell", "am", "force-stop", PACKAGE], args.serial)
        adb(["shell", "am", "start", "-n", ACTIVITY], args.serial)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as ex:
        print(f"\nfailed: {' '.join(str(c) for c in ex.cmd)}", file=sys.stderr)
        sys.exit(ex.returncode)
    except (RuntimeError, OSError, ValueError, AssertionError) as ex:
        print(f"\nfailed: {ex}", file=sys.stderr)
        sys.exit(1)
