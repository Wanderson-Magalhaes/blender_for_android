# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Device half of run_render_regressions.py, in an unsaved factory scene."""

import json
import math
from pathlib import Path
import sys
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy
from bpy_extras.view3d_utils import location_3d_to_region_2d
from mathutils import Quaternion, Vector
import numpy as np

from render_fixture import (
    FACES, MOTION_SECONDS, compare, configure, fixture_hash, motion_material,
    render_linear, restore_material,
)

args = sys.argv[sys.argv.index("--") + 1:]
output, reference_directory = map(Path, args[:2])
output.mkdir(parents=True, exist_ok=True)
report = {"schema": 2, "complete": False, "passed": False, "phase": "starting", "tests": {},
          "motion_frames": 0, "motion_duration": 0, "fixture_sha256": fixture_hash(),
          "version": bpy.app.version_string, "build_hash": bpy.app.build_hash.decode()}
scene = configure()
manifest = json.loads((reference_directory / "reference.json").read_text())
assert manifest["fixture_sha256"] == fixture_hash(), "Reference fixture differs from test"
assert tuple(manifest["producer"]["version_tuple"][:2]) == bpy.app.version[:2], "Reference version mismatch"
canonical = np.load(str(reference_directory / "cycles-default.npy"))
window = bpy.context.window_manager.windows[0]
area = next(a for a in window.screen.areas if a.type == "VIEW_3D")
space = area.spaces.active
region = next(r for r in area.regions if r.type == "WINDOW")
context = {"window": window, "area": area, "region": region}
original = (scene.render.engine, space.shading.type, space.region_3d.view_rotation.copy(),
            space.region_3d.view_distance)
space.overlay.show_overlays = False
space.shading.use_scene_lights_render = space.shading.use_scene_world_render = True
space.region_3d.view_location = (0, 0, 0)
space.region_3d.view_distance = 9
base_rotation = scene.camera.matrix_world.to_quaternion()
space.region_3d.view_rotation = base_rotation
phase = "cold"
iteration = 0
motion_start = None
saved_materials = None


def write_report():
    temporary = output / "results.tmp"
    temporary.write_text(json.dumps(report))
    temporary.replace(output / "results.json")


def projected_faces():
    return {
        name: [float(p.x + region.x), float(p.y + region.y)]
        for name, point in FACES.items()
        if (p := location_3d_to_region_2d(region, space.region_3d, Vector(point))) is not None
    }


def finish(error=None):
    global saved_materials
    if saved_materials is not None:
        restore_material(saved_materials)
        saved_materials = None
    scene.render.engine, space.shading.type = original[:2]
    space.region_3d.view_rotation, space.region_3d.view_distance = original[2:]
    if error:
        report["error"] = error
    report["complete"] = True
    # The host independently approves motion using composed Android screenshots.
    report["passed"] = (not error and iteration == 8
                        and report["motion_frames"] >= 180
                        and report["motion_duration"] >= MOTION_SECONDS - 0.2
                        and len(report["tests"]) == 10
                        and all(t["passed"] for t in report["tests"].values()))
    report["phase"] = "complete"
    write_report()
    print("ANDROID_RENDER_REGRESSIONS", json.dumps(report), flush=True)


def tick():
    global phase, iteration, motion_start, saved_materials
    try:
        report["phase"] = phase
        if phase == "cold":
            space.shading.type = "SOLID"
            scene.render.engine = "CYCLES"
            report["tests"]["cycles_cold"] = compare(
                render_linear(scene, output, "cycles-cold", context), canonical)
            saved_materials = motion_material()
            scene.render.engine = "BLENDER_EEVEE"
            space.shading.type = "RENDERED"
            phase = "motion_ready"
            report.update(phase=phase, faces=projected_faces(),
                          window_size=[window.width, window.height])
            write_report()
            return 3.0
        if phase == "motion_ready":
            if not (output / "motion-start").exists():
                return 0.2
            motion_start = time.monotonic()
            phase = "orbit"
            return 0.03
        if phase == "orbit":
            elapsed = time.monotonic() - motion_start
            angle = 0.35 * math.sin(elapsed * 1.5)
            space.region_3d.view_rotation = Quaternion((0, 0, 1), angle) @ base_rotation
            area.tag_redraw()
            report.update(phase="orbit", motion_duration=elapsed, angle=angle,
                          motion_frames=report["motion_frames"] + 1, faces=projected_faces())
            write_report()
            if elapsed < MOTION_SECONDS:
                return 0.03
            report["phase"] = "eevee_final"
            write_report()
            restore_material(saved_materials)
            saved_materials = None
            space.region_3d.view_rotation = base_rotation
            phase = "eevee_final"
            return 2.0
        if phase == "eevee_final":
            report["tests"]["eevee_final"] = compare(
                render_linear(scene, output, "eevee-final", context), canonical, eevee=True)
            scene.render.engine = "CYCLES"
            phase = "cycles"
            return 5.0
        if phase == "cycles":
            name = "cycles_after_viewport_" + str(iteration)
            report["tests"][name] = compare(
                render_linear(scene, output, "cycles-after-viewport-" + str(iteration), context),
                canonical)
            iteration += 1
            if iteration == 8:
                finish()
                return None
            space.region_3d.view_rotation = Quaternion((0, 0, 1), 0.1 * iteration) @ base_rotation
            area.tag_redraw()
            write_report()
            return 2.0
    except Exception:
        finish(traceback.format_exc())
        return None
    write_report()
    return 0.1


write_report()
bpy.app.timers.register(tick, first_interval=3.0)
