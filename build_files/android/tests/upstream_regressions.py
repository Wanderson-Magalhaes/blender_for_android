# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Android process test: --python SCRIPT -- RESULT.json [native|ui].

Run native mode before and after updating. The larger backing allocation keeps
the pre-fix path overflow within allocated memory while canaries detect it.
Full mode additionally tests GPU API access during startup and draw readback.
The ui mode also switches a real editor between File and Asset Browser modes.
This script does not change the scene or save preferences.
"""

import ctypes
import json
from pathlib import Path
import sys
import traceback

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
result_path = Path(args[0])
results = {"version": bpy.app.version_string, "tests": {}, "complete": False}


def check(name, function):
    try:
        detail = function()
        results["tests"][name] = {"passed": True, "detail": detail}
    except Exception:
        results["tests"][name] = {"passed": False, "error": traceback.format_exc()}
    result_path.write_text(json.dumps(results, indent=2), encoding="utf-8")


library = ctypes.CDLL("libblender.so")
frame = getattr(library, "_ZN7blender14BLI_path_frameEPcmii")
frame_range = getattr(library, "_ZN7blender20BLI_path_frame_rangeEPcmiii")
frame.argtypes = [ctypes.POINTER(ctypes.c_char), ctypes.c_size_t, ctypes.c_int, ctypes.c_int]
frame_range.argtypes = frame.argtypes + [ctypes.c_int]
frame.restype = frame_range.restype = ctypes.c_bool


def guarded(function, parameters):
    buffer = ctypes.create_string_buffer(13)
    expected = b"test_ab\0" + b"\xff" * 4 + b"\0"
    buffer.raw = expected
    returned = function(buffer, 8, *parameters)
    assert not returned and buffer.raw == expected, (returned, buffer.raw.hex())
    return {"returned": returned, "bytes": buffer.raw.hex()}


def normal_path():
    buffer = ctypes.create_string_buffer(b"image_", 64)
    assert frame(buffer, 64, 123, 4)
    assert buffer.value == b"image_0123", buffer.value
    return buffer.value.decode()


check("path_frame_canaries", lambda: guarded(frame, (123, 4)))
check("path_frame_range_canaries", lambda: guarded(frame_range, (1, 2, 4)))
check("path_frame_normal", normal_path)

if not (len(args) > 1 and args[1] == "native"):
    import gpu
    from gpu_extras.batch import batch_for_shader
    from mathutils import Matrix

    def startup_shaders():
        gpu.shader.from_builtin("UNIFORM_COLOR")
        gpu.shader.from_builtin("UNIFORM_COLOR", config="CLIPPED")
        return "Shaders created directly during --python startup"

    def draw_readback():
        shader = gpu.shader.from_builtin("UNIFORM_COLOR")
        batch = batch_for_shader(shader, "TRIS", {"pos": [(-0.5, -0.5, 0),
                                                          (0.5, -0.5, 0), (0, 0.5, 0)]})
        observations = []
        for width, height in ((31, 29), (64, 64), (97, 71)):
            offscreen = gpu.types.GPUOffScreen(width, height)
            try:
                with offscreen.bind(), gpu.matrix.push_pop():
                    gpu.matrix.load_identity()
                    gpu.matrix.load_projection_matrix(Matrix.Identity(4))
                    framebuffer = gpu.state.active_framebuffer_get()
                    framebuffer.clear(color=(0, 0, 0, 1))
                    shader.bind()
                    shader.uniform_float("color", (1, 0, 0, 1))
                    batch.draw(shader)
                    center = framebuffer.read_color(width // 2, height // 2, 1, 1,
                                                    4, 0, "FLOAT").to_list()[0][0]
                    corner = framebuffer.read_color(0, 0, 1, 1, 4, 0, "FLOAT").to_list()[0][0]
                    assert center[0] > 0.9 and center[1] < 0.1, center
                    assert max(corner[:3]) < 0.1, corner
                    observations.append({"size": [width, height], "center": center,
                                         "corner": corner})
            finally:
                offscreen.free()
        return observations

    check("gpu_api_at_startup", startup_shaders)
    check("gpu_draw_resize_readback", draw_readback)

def finish():
    results["complete"] = True
    result_path.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print("ANDROID_UPSTREAM_REGRESSIONS", json.dumps(results), flush=True)


if "ui" in args[1:]:
    area = max(bpy.context.window.screen.areas, key=lambda item: item.width * item.height)
    previous_type = area.type
    transitions = iter(("FILES", "ASSETS", "FILES", "ASSETS", "FILES"))
    observed = []

    def browser_transition():
        try:
            subtype = next(transitions)
            area.type = "FILE_BROWSER"
            area.ui_type = subtype
            observed.append(area.ui_type)
            return 1.0
        except StopIteration:
            results["tests"]["file_asset_browser_transitions"] = {
                "passed": True, "detail": observed}
        except Exception:
            results["tests"]["file_asset_browser_transitions"] = {
                "passed": False, "error": traceback.format_exc()}
        finally:
            if "file_asset_browser_transitions" in results["tests"]:
                area.type = previous_type
                finish()
        return None

    bpy.app.timers.register(browser_transition, first_interval=3.0)
else:
    finish()
