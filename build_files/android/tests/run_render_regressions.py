#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Validate one exact APK on a named Android device. No clear/uninstall or saved preferences.

Requires an official desktop reference made by create_render_reference.py, adb and ffmpeg.
Exit 0 means CPU renders AND composed EEVEE frames during continuous motion passed.
Missing prerequisites, missing frames, stale results, crashes and timeouts fail closed.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import struct
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
PACKAGE = "org.blender.blender"
FILES = "/sdcard/Android/data/" + PACKAGE + "/files"
ARGS_FILE = FILES + "/blender_args.txt"
MOTION_LIMIT = 0.10  # Mean display-RGB error at each face center, against official CPU reference.
MIN_CAPTURES = 24


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def find_tool(name, explicit=None):
    explicit = explicit or os.environ.get(name.upper())
    if explicit:
        path = shutil.which(str(explicit)) or str(explicit)
        if Path(path).is_file():
            return path
        raise RuntimeError("Missing executable: " + path)
    for candidate in (name, name + ".exe"):
        if path := shutil.which(candidate):
            return path
    patterns = {
        "adb": "/mnt/c/Users/*/AppData/Local/Android/Sdk/platform-tools/adb.exe",
        "ffmpeg": "/mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg*/ffmpeg*/bin/ffmpeg.exe",
    }
    import glob
    matches = sorted(glob.glob(patterns[name]))
    if matches:
        return matches[0]
    raise RuntimeError("Missing " + name + "; pass --" + name + " /path/to/" + name)


def executable_path(path, executable):
    if str(executable).lower().endswith(".exe") and os.name != "nt":
        return subprocess.check_output(["wslpath", "-w", str(Path(path).resolve())], text=True).strip()
    return str(Path(path).resolve())


def check_reference(directory):
    directory = Path(directory).resolve()
    manifest = json.loads((directory / "reference.json").read_text())
    if manifest["schema"] != 1:
        raise RuntimeError("Unsupported reference schema")
    if manifest["producer"]["platform"] == "android":
        raise RuntimeError("Candidate cannot be its own reference")
    expected = sha256(HERE / "render_fixture.py")
    if manifest["fixture_sha256"] != expected:
        raise RuntimeError("Reference fixture differs; regenerate officially")
    for name in ("cycles-default.npy", "cycles-default.png", "motion-diffuse.png"):
        if manifest["files"][name] != sha256(directory / name):
            raise RuntimeError("Reference hash mismatch: " + name)
    if set(manifest["motion_face_points"]) != {"X+", "Y-", "Z+"}:
        raise RuntimeError("Missing reference faces")
    return manifest


class Device:
    def __init__(self, adb, serial):
        self.adb, self.serial = adb, serial

    def call(self, *args, check=True, timeout=30):
        result = subprocess.run(
            [self.adb, "-s", self.serial, *map(str, args)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace")
                               + result.stdout.decode(errors="replace"))
        return result

    def text(self, *args, **kwargs):
        return self.call(*args, **kwargs).stdout.decode(errors="replace").replace("\r", "")

    def push(self, path, remote):
        return self.call("push", executable_path(path, self.adb), remote)

    def pull(self, remote, path):
        # Read through stdout: adb.exe cannot write into root-owned WSL output directories.
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.call("exec-out", "cat", remote, timeout=90).stdout)

    def pull_tree(self, remote, path):
        from pathlib import PurePosixPath
        for name in self.text("shell", "find", remote, "-type", "f").splitlines():
            relative = PurePosixPath(name).relative_to(PurePosixPath(remote))
            if ".." in relative.parts:
                raise RuntimeError("Unexpected output path")
            self.pull(name, Path(path).joinpath(*relative.parts))

    def foreground(self):
        focus = self.text("shell", "dumpsys window | grep mCurrentFocus")
        if PACKAGE + "/" not in focus:
            raise RuntimeError("Blender lost foreground; motion capture aborted")


def decode_png(png, ffmpeg, scale=1):
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("Invalid screenshot PNG")
    width, height = struct.unpack(">II", png[16:24])
    width, height = width // scale, height // scale
    result = subprocess.run(
        [ffmpeg, "-v", "error", "-threads", "1", "-filter_threads", "1",
         "-f", "image2pipe", "-i", "pipe:0", "-vf", f"scale={width}:{height}",
         "-frames:v", "1", "-threads", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"],
        input=png, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=True)
    if len(result.stdout) != width * height * 3:
        raise RuntimeError("Incomplete decoded image")
    return width, height, result.stdout


def sample_rgb(image, point, radius=2):
    width, height, rgb = image
    x, y = map(round, point)
    if not (radius <= x < width - radius and radius <= y < height - radius):
        raise RuntimeError("Face sample fell outside the composed image")
    return [
        statistics.median(rgb[((yy * width + xx) * 3) + channel]
                          for yy in range(y - radius, y + radius + 1)
                          for xx in range(x - radius, x + radius + 1)) / 255
        for channel in range(3)
    ]


def motion_sample(image, before, after, expected):
    width, height, _ = image
    scale = width / before["window_size"][0]
    if scale not in (0.5, 1.0) or before["window_size"] != after["window_size"]:
        raise RuntimeError("Display size/orientation changed during motion")
    errors, observed = {}, {}
    for face, reference in expected.items():
        first, second = before["faces"][face], after["faces"][face]
        point = [(first[0] + second[0]) * scale / 2, height - (first[1] + second[1]) * scale / 2]
        observed[face] = sample_rgb(image, point)
        errors[face] = sum(abs(a - b) for a, b in zip(observed[face], reference)) / 3
    return {"errors": errors, "observed": observed,
            "worst_error": max(errors.values()), "passed": max(errors.values()) < MOTION_LIMIT}


def approve_motion(samples):
    times = [sample["time"] for sample in samples]
    angles = [sample["angle"] for sample in samples]
    frames = {sample["frame"] for sample in samples}
    passed = (len(samples) >= MIN_CAPTURES and len(frames) >= MIN_CAPTURES
              and max(times, default=0) - min(times, default=0) >= 30
              and max(angles, default=0) - min(angles, default=0) >= 0.60
              and all(sample["passed"] for sample in samples))
    return {"passed": passed, "captures": len(samples), "distinct_motion_frames": len(frames),
            "sampled_seconds": max(times, default=0) - min(times, default=0),
            "angle_span": max(angles, default=0) - min(angles, default=0),
            "worst_face_error": max((s["worst_error"] for s in samples), default=1),
            "limit": MOTION_LIMIT}


def preflight(reference, serial, adb=None, ffmpeg=None):
    manifest = check_reference(reference)
    device = Device(find_tool("adb", adb), serial)
    decoder = find_tool("ffmpeg", ffmpeg)
    if device.text("get-state").strip() != "device":
        raise RuntimeError("Named device is not ready")
    # Prove image decoding works before replacing the installed APK.
    decode_png((Path(reference) / "motion-diffuse.png").read_bytes(), decoder)
    return device, decoder, manifest


def run_candidate(apk, reference, output, serial, *, adb=None, ffmpeg=None, timeout=300):
    apk, reference, output = map(lambda p: Path(p).resolve(), (apk, reference, output))
    output.mkdir(parents=True, exist_ok=False)
    report = {"schema": 1, "passed": False, "apk": str(apk), "serial": serial,
              "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "samples": []}
    device = None
    saved_args = None
    args_changed = False
    remote = FILES + "/render-release-" + uuid.uuid4().hex
    device_report = {}
    try:
        report["apk_sha256"] = sha256(apk)
        device, decoder, manifest = preflight(reference, serial, adb, ffmpeg)
        report["reference"] = manifest
        report["device_model"] = device.text("shell", "getprop", "ro.product.model").strip()
        original = device.call("shell", "cat", ARGS_FILE, check=False)
        if original.returncode == 0:
            saved_args = original.stdout
        device.call("install", "-r", executable_path(apk, device.adb), timeout=120)
        device.call("shell", "mkdir", "-p", remote + "/reference", remote + "/output")
        for name in ("render_fixture.py", "render_regressions.py"):
            device.push(HERE / name, remote + "/" + name)
        for name in ("reference.json", "cycles-default.npy"):
            device.push(reference / name, remote + "/reference/" + name)
        local_args = output / "launch-args.txt"
        local_args.write_text("--factory-startup --python " + remote
                              + "/render_regressions.py -- " + remote + "/output " + remote + "/reference")
        device.push(local_args, ARGS_FILE)
        args_changed = True
        device.call("shell", "am", "force-stop", PACKAGE)
        device.call("shell", "am", "start", "-n", PACKAGE + "/.BlenderActivity")
        expected_image = decode_png((reference / "motion-diffuse.png").read_bytes(), decoder)
        expected = {name: sample_rgb(expected_image, point)
                    for name, point in manifest["motion_face_points"].items()}
        report["expected_faces"] = expected
        if max(sum(v) for v in expected.values()) - min(sum(v) for v in expected.values()) < 0.45:
            raise RuntimeError("Reference lacks lighting contrast needed to detect the EEVEE regression")
        armed = False
        deadline = time.monotonic() + timeout
        last_phase = None

        def read_status():
            value = device.call("shell", "cat", remote + "/output/results.json", check=False)
            return json.loads(value.stdout) if value.returncode == 0 else {}

        while time.monotonic() < deadline:
            state = read_status()
            if state.get("phase") != last_phase:
                last_phase = state.get("phase")
                print("[render-test]", last_phase or "starting", flush=True)
            if state.get("complete"):
                device_report = state
                break
            if state.get("phase") == "motion_ready" and not armed:
                time.sleep(3)
                device.foreground()
                device.call("shell", "touch", remote + "/output/motion-start")
                armed = True
            elif state.get("phase") == "orbit" and state.get("motion_duration", 0) > 0.75:
                device.foreground()
                png = device.call("exec-out", "screencap", "-p").stdout
                after = read_status()
                if after.get("phase") != "orbit":
                    continue
                sample = motion_sample(decode_png(png, decoder, scale=2), state, after, expected)
                sample.update(time=state["motion_duration"], angle=state["angle"],
                              frame=state["motion_frames"])
                report["samples"].append(sample)
                (output / ("motion-%04d.png" % len(report["samples"]))).write_bytes(png)
                print("[motion]", len(report["samples"]), "error=%.4f" % sample["worst_error"],
                      "PASS" if sample["passed"] else "FAIL", flush=True)
            else:
                time.sleep(0.25)
        else:
            raise TimeoutError("Render checks did not finish within " + str(timeout) + " seconds")
        report["device_tests"] = device_report
        report["eevee_motion"] = approve_motion(report["samples"])
        report["passed"] = bool(device_report.get("passed") and report["eevee_motion"]["passed"])
        if sha256(apk) != report["apk_sha256"]:
            raise RuntimeError("APK changed while it was being validated")
        device.pull_tree(remote + "/output", output / "device-output")
        device.pull(remote + "/reference/reference.json", output / "reference-used.json")
    except Exception as error:
        report.update(passed=False, error=type(error).__name__ + ": " + str(error))
        if device:
            if not device_report.get("complete"):
                device.call("shell", "am", "force-stop", PACKAGE, check=False)
            (output / "logcat-crash.txt").write_bytes(
                device.call("logcat", "-b", "crash", "-d", check=False).stdout)
    finally:
        if device and args_changed:
            try:
                if saved_args is None:
                    device.call("shell", "rm", "-f", ARGS_FILE)
                else:
                    backup = output / "launch-args-before.txt"
                    backup.write_bytes(saved_args)
                    device.push(backup, ARGS_FILE)
            except Exception as error:
                report.update(passed=False, cleanup_error=str(error))
        report["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (output / "report.json").write_text(json.dumps(report, indent=2))
    print("RENDER_RELEASE_GATE", "PASS" if report["passed"] else "FAIL",
          str(output / "report.json"), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="new directory for this exact run")
    parser.add_argument("-s", "--serial", required=True)
    parser.add_argument("--adb")
    parser.add_argument("--ffmpeg")
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    report = run_candidate(args.apk, args.reference, args.output, args.serial,
                           adb=args.adb, ffmpeg=args.ffmpeg, timeout=args.timeout)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
