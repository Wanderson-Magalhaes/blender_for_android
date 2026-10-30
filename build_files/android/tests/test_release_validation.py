#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Host tests for the fail-closed release decision; no device or Blender needed."""

import copy
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent)]
import run_render_regressions as runner
from release_validation import promote


def good_motion():
    return [{"time": float(i), "frame": i * 10, "angle": -0.35 + i * 0.7 / 39,
             "passed": True, "worst_error": 0.01} for i in range(40)]


def good_report(apk):
    tests = {name: {"passed": True} for name in
             ["cycles_cold", "eevee_final"] + ["cycles_after_viewport_" + str(i) for i in range(8)]}
    return {"passed": True, "apk_sha256": runner.sha256(apk),
            "device_tests": {"complete": True, "passed": True, "tests": tests},
            "eevee_motion": runner.approve_motion(good_motion())}


class MotionTests(unittest.TestCase):
    def test_complete_healthy_orbit(self):
        self.assertTrue(runner.approve_motion(good_motion())["passed"])

    def test_static_screenshot_cannot_approve_motion(self):
        samples = good_motion()
        for sample in samples:
            sample.update(angle=0, frame=1)
        self.assertFalse(runner.approve_motion(samples)["passed"])

    def test_one_bad_lighting_frame_blocks_release(self):
        samples = good_motion()
        samples[12].update(passed=False, worst_error=0.4)
        self.assertFalse(runner.approve_motion(samples)["passed"])

    def test_missing_or_short_capture_blocks_release(self):
        self.assertFalse(runner.approve_motion([])["passed"])
        self.assertFalse(runner.approve_motion(good_motion()[:10])["passed"])
        samples = good_motion()
        for sample in samples:
            sample["time"] /= 10
        self.assertFalse(runner.approve_motion(samples)["passed"])

    def test_flat_lighting_is_detected_in_composed_pixels(self):
        image = (40, 40, bytes([128, 128, 128]) * 1600)
        state = {"window_size": [40, 40],
                 "faces": {"X+": [10, 30], "Y-": [20, 30], "Z+": [30, 30]}}
        expected = {"X+": [0.5] * 3, "Y-": [0.1] * 3, "Z+": [0.8] * 3}
        self.assertFalse(runner.motion_sample(image, state, state, expected)["passed"])


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.apk = self.root / "blender-full.apk"
        self.apk.write_bytes(b"exact candidate bytes")
        self.releases = self.root / "releases"

    def test_only_exact_passed_candidate_is_promoted(self):
        target = promote(self.apk, good_report(self.apk), self.releases)
        self.assertEqual(target.read_bytes(), self.apk.read_bytes())
        self.assertTrue(json.loads(target.with_suffix(".render-check.json").read_text())["passed"])

    def test_failure_or_incomplete_evidence_creates_no_release(self):
        changes = (
            lambda r: r.update(passed=False),
            lambda r: r["device_tests"].update(complete=False),
            lambda r: r["device_tests"].update(passed=False),
            lambda r: r["device_tests"]["tests"].pop("cycles_after_viewport_7"),
            lambda r: r["device_tests"]["tests"]["cycles_cold"].update(passed=False),
            lambda r: r["eevee_motion"].update(passed=False),
            lambda r: r.update(apk_sha256="stale hash"),
        )
        for change in changes:
            with self.subTest(change=change):
                report = copy.deepcopy(good_report(self.apk))
                change(report)
                with self.assertRaises(RuntimeError):
                    promote(self.apk, report, self.releases)
                self.assertFalse(self.releases.exists())

    def test_apk_changed_after_test_is_rejected(self):
        report = good_report(self.apk)
        self.apk.write_bytes(b"a different APK")
        with self.assertRaises(RuntimeError):
            promote(self.apk, report, self.releases)
        self.assertFalse(self.releases.exists())

    def test_reference_integrity_is_checked_with_python_optimization(self):
        manifest = {"schema": 1, "producer": {"platform": "win32"},
                    "fixture_sha256": "not the current fixture"}
        (self.root / "reference.json").write_text(json.dumps(manifest))
        code = ("import sys; sys.path.insert(0, " + repr(str(HERE)) + "); "
                "import run_render_regressions as r; r.check_reference(" + repr(str(self.root)) + ")")
        result = subprocess.run([sys.executable, "-O", "-c", code], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Reference fixture differs", result.stderr)

    def test_reference_flag_alone_cannot_look_like_a_validated_build(self):
        import build
        from contextlib import redirect_stderr
        import io
        with (patch.object(sys, "argv", ["build.py", "full", "--render-reference", str(self.root)]),
              patch.object(build, "build") as build_step,
              redirect_stderr(io.StringIO())):
            with self.assertRaises(SystemExit) as caught:
                build.main()
            self.assertEqual(caught.exception.code, 2)
            build_step.assert_not_called()

    def test_build_release_calls_gate_before_archiving(self):
        import build
        events = []
        argv = ["build.py", "full", "--release", "--serial", "test-device",
                "--render-reference", str(self.root)]
        with (patch.object(sys, "argv", argv),
              patch.object(runner, "preflight", side_effect=lambda *a: events.append("preflight")),
              patch.object(build, "build", side_effect=lambda *a, **k: events.append(("build", k))),
              patch("release_validation.validate_release", side_effect=RuntimeError("blocked")),
              patch.object(build, "archive_apk") as archive):
            with self.assertRaisesRegex(RuntimeError, "blocked"):
                build.main()
            archive.assert_not_called()
        self.assertEqual(events[0], "preflight")
        self.assertTrue(events[1][1]["repackage"])
        self.assertFalse(self.releases.exists())

    def test_missing_prerequisites_write_a_failure_report(self):
        output = self.root / "failed-check"
        with patch.object(runner, "preflight", side_effect=RuntimeError("missing official reference")):
            report = runner.run_candidate(self.apk, self.root, output, "named-test-device")
        self.assertFalse(report["passed"])
        self.assertIn("missing official reference", report["error"])
        self.assertFalse(json.loads((output / "report.json").read_text())["passed"])


if __name__ == "__main__":
    unittest.main()
