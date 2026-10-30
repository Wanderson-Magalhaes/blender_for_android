# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Only promote APKs whose render gate passed for the exact same bytes."""

import datetime
import json
from pathlib import Path
import shutil
import sys
import uuid

TESTS = Path(__file__).resolve().parent / "tests"
sys.path.insert(0, str(TESTS))
from run_render_regressions import run_candidate, sha256


def promote(apk, report, release_directory):
    """Called only after the device checks; refuse incomplete or mismatched evidence."""
    apk, release_directory = Path(apk), Path(release_directory)
    device = report.get("device_tests", {})
    tests = device.get("tests", {})
    required = {"cycles_cold", "eevee_final"} | {
        "cycles_after_viewport_" + str(i) for i in range(8)}
    if (report.get("passed") is not True or device.get("complete") is not True
            or device.get("passed") is not True or set(tests) != required
            or not all(test.get("passed") is True for test in tests.values())
            or report.get("eevee_motion", {}).get("passed") is not True):
        raise RuntimeError("Release blocked: render evidence failed or is incomplete")
    digest = sha256(apk)
    if report.get("apk_sha256") != digest:
        raise RuntimeError("Release blocked: APK differs from the tested candidate")
    release_directory.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")
    target = release_directory / (apk.stem + "-" + stamp + "-" + digest[:8] + ".apk")
    evidence = target.with_suffix(".render-check.json")
    pending_apk = target.with_suffix(".apk.tmp")
    pending_evidence = evidence.with_suffix(".json.tmp")
    try:
        shutil.copy2(apk, pending_apk)
        if sha256(pending_apk) != digest:
            raise RuntimeError("Release blocked: copied APK checksum differs")
        pending_evidence.write_text(json.dumps(report, indent=2))
        pending_evidence.replace(evidence)
        pending_apk.replace(target)
    except Exception:
        pending_apk.unlink(missing_ok=True)
        pending_evidence.unlink(missing_ok=True)
        evidence.unlink(missing_ok=True)
        raise
    print("[release] verified APK:", target, flush=True)
    print("[release] evidence:", evidence, flush=True)
    return target


def validate_release(apk, reference, build_base, serial):
    root = Path(build_base) / "release_checks" / (
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")
        + "-" + uuid.uuid4().hex[:8])
    root.mkdir(parents=True)
    # Freeze bytes even if another ordinary build updates the stage during the test.
    candidate = root / Path(apk).name
    shutil.copy2(apk, candidate)
    report = run_candidate(candidate, reference, root / "results", serial)
    return promote(candidate, report, Path(build_base) / "apk" / "releases")
