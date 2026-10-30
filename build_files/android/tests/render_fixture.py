# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Shared, deterministic scene for official references and Android release checks."""

import hashlib
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

SIZE = 256
SAMPLES = 32
MOTION_SECONDS = 40.0
FACES = {"X+": (1, 0, 0), "Y-": (0, -1, 0), "Z+": (0, 0, 1)}


def fixture_hash():
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def configure():
    assert not bpy.data.filepath, "Use --factory-startup, never a user's project"
    scene = bpy.context.scene
    cube = scene.objects.get("Cube")
    assert cube and scene.camera and scene.objects.get("Light"), "Missing factory objects"
    assert all(abs(d - 2) < 1e-4 for d in cube.dimensions), "Unexpected cube"
    bpy.context.preferences.use_preferences_save = False
    bpy.context.preferences.view.show_splash = False
    scene.render.resolution_x = scene.render.resolution_y = SIZE
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.preview_samples = 16
    scene.cycles.use_denoising = scene.cycles.use_preview_denoising = False
    scene.cycles.seed = 0
    scene.render.preview_pixel_size = "4"
    scene.objects["Light"].data.energy = 1000
    return scene


def motion_material():
    """A Lambertian surface makes face lighting independent of the moving view."""
    material = bpy.data.materials.new("Release Test Diffuse")
    material.use_nodes = True
    material.node_tree.nodes.clear()
    diffuse = material.node_tree.nodes.new("ShaderNodeBsdfDiffuse")
    diffuse.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
    diffuse.inputs["Roughness"].default_value = 0
    output = material.node_tree.nodes.new("ShaderNodeOutputMaterial")
    material.node_tree.links.new(diffuse.outputs["BSDF"], output.inputs["Surface"])
    cube = bpy.context.scene.objects["Cube"]
    saved = list(cube.data.materials)
    cube.data.materials.clear()
    cube.data.materials.append(material)
    return saved


def restore_material(materials):
    slots = bpy.context.scene.objects["Cube"].data.materials
    slots.clear()
    for material in materials:
        slots.append(material)


def render_linear(scene, output, name, context=None):
    """Save display PNG plus unclipped, scene-linear float pixels."""
    output = Path(output)
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_depth = "8"
    scene.render.filepath = str(output / (name + ".png"))
    if context:
        with bpy.context.temp_override(**context):
            bpy.ops.render.render(write_still=True)
    else:
        bpy.ops.render.render(write_still=True)
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_depth = "32"
    path = output / (name + ".exr")
    bpy.data.images["Render Result"].save_render(str(path), scene=scene)
    image = bpy.data.images.load(str(path), check_existing=False)
    try:
        pixels = np.empty(len(image.pixels), dtype=np.float32)
        image.pixels.foreach_get(pixels)
        pixels = pixels.reshape((SIZE, SIZE, 4))
        assert np.isfinite(pixels).all(), "Non-finite rendered pixels"
        np.save(str(output / (name + ".npy")), pixels)
        return pixels
    finally:
        bpy.data.images.remove(image)


def compare(pixels, canonical, *, eevee=False):
    difference = np.abs(pixels[:, :, :3] - canonical[:, :, :3])
    roi = difference[95:160, 95:165]
    metrics = {
        "mean_absolute_linear_error": float(difference.mean()),
        "roi_error": float(roi.mean()),
        "worst_roi_row_error": float(roi.mean(axis=(1, 2)).max()),
        "mean_linear": float(pixels[95:160, 95:165, :3].mean()),
    }
    # The zeroed-stack diagnostic (ROI error 0.00235) must also fail.
    limits = (0.02, 0.02, 0.035) if eevee else (0.001, 0.001, 0.005)
    metrics["passed"] = all(metrics[key] < limit for key, limit in zip(
        ("mean_absolute_linear_error", "roi_error", "worst_roi_row_error"), limits))
    return metrics


def camera_face_points(scene):
    from bpy_extras.object_utils import world_to_camera_view
    points = {}
    for name, point in FACES.items():
        projected = world_to_camera_view(scene, scene.camera, Vector(point))
        points[name] = [projected.x * SIZE, (1 - projected.y) * SIZE]
    return points