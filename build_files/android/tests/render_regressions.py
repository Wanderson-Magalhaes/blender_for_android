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
from bpy_extras.object_utils import world_to_camera_view
from bpy_extras.view3d_utils import location_3d_to_region_2d
from mathutils import Quaternion, Vector
import gpu
import numpy as np

from render_fixture import (
    FACES, MOTION_SECONDS, SIZE, compare, configure, fixture_hash, motion_material,
    render_linear, restore_material,
)

args = sys.argv[sys.argv.index("--") + 1:]
output, reference_directory = map(Path, args[:2])
output.mkdir(parents=True, exist_ok=True)
report = {"schema": 3, "complete": False, "passed": False, "phase": "starting", "tests": {},
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
SHADOW_PLANE_Z = -1.2189
SHADOW_POINTS = {
    "shadow": Vector((-1.35, -0.95, SHADOW_PLANE_Z)),
    "lit": Vector((1.65, -0.95, SHADOW_PLANE_Z)),
}


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


def setup_shadow_scene():
    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.use_shadows = True
    scene.eevee.taa_samples = scene.eevee.taa_render_samples = 16
    scene.render.preview_pixel_size = "2"
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0
    light = scene.objects["Light"]
    light.location = (4, 3, 5)
    light.data.energy = 2000
    light.data.shadow_soft_size = 0.1
    light.data.use_shadow = True

    bpy.ops.mesh.primitive_plane_add(size=6.928, location=(0, 0, SHADOW_PLANE_Z))
    bpy.context.object.data.materials.append(scene.objects["Cube"].data.materials[0])

    target = Vector((0, 0, -0.45))
    camera = scene.camera
    camera.location = (3, -8, 5)
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = 42
    bpy.context.view_layer.update()
    report["shadow_render_points"] = {}
    for name, point in SHADOW_POINTS.items():
        uv = world_to_camera_view(scene, camera, point)
        report["shadow_render_points"][name] = [uv.x * SIZE, (1 - uv.y) * SIZE]

    view = space.region_3d
    view.view_rotation = camera.rotation_euler.to_quaternion()
    view.view_location = target
    view.view_distance = 10
    view.view_perspective = "ORTHO"
    space.shading.type = "RENDERED"
    area.tag_redraw()


def shadow_viewport_points():
    points = {}
    for name, point in SHADOW_POINTS.items():
        screen = location_3d_to_region_2d(region, space.region_3d, point)
        if screen is None or not (0 <= screen.x < region.width and 0 <= screen.y < region.height):
            raise RuntimeError("Shadow sample fell outside the viewport")
        points[name] = [screen.x + region.x, screen.y + region.y]
    return points


def render_shadow_pair():
    light = scene.objects["Light"].data
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_depth = "8"
    with bpy.context.temp_override(**context):
        for mode in ("on", "off"):
            light.use_shadow = mode == "on"
            scene.render.filepath = str(output / ("shadow-render-" + mode + ".png"))
            bpy.ops.render.render(write_still=True)


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
    # The host independently approves motion and both shadow comparisons.
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
            report["gpu"] = {"renderer": gpu.platform.renderer_get(),
                             "driver": gpu.platform.version_get()}
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
                saved_materials = motion_material()
                with bpy.context.temp_override(**context):
                    setup_shadow_scene()
                phase = "shadow_viewport_on"
                return 4.0
            space.region_3d.view_rotation = Quaternion((0, 0, 1), 0.1 * iteration) @ base_rotation
            area.tag_redraw()
            write_report()
            return 2.0
        if phase in {"shadow_viewport_on", "shadow_viewport_off"}:
            report.update(shadow_viewport_points=shadow_viewport_points(),
                          window_size=[window.width, window.height])
            write_report()
            if not (output / (phase + "-captured")).exists():
                return 0.25
            if phase == "shadow_viewport_on":
                scene.objects["Light"].data.use_shadow = False
                area.tag_redraw()
                phase = "shadow_viewport_off"
                return 3.0
            space.shading.type = "SOLID"
            phase = "shadow_render"
            return 0.5
        if phase == "shadow_render":
            write_report()
            render_shadow_pair()
            finish()
            return None
    except Exception:
        finish(traceback.format_exc())
        return None
    write_report()
    return 0.1


write_report()
bpy.app.timers.register(tick, first_interval=3.0)
