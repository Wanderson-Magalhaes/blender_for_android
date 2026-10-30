# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Run in an official desktop Blender:
blender --background --factory-startup --python create_render_reference.py -- OUTPUT
Never generate the reference from the Android candidate under test.
"""

import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy
from render_fixture import camera_face_points, configure, fixture_hash, motion_material, render_linear

assert sys.platform != "android", "An Android candidate cannot approve its own reference"
output = Path(sys.argv[sys.argv.index("--") + 1]).resolve()
output.mkdir(parents=True, exist_ok=True)
scene = configure()
scene.render.engine = "CYCLES"
render_linear(scene, output, "cycles-default")
motion_material()
render_linear(scene, output, "motion-diffuse")
files = ("cycles-default.npy", "cycles-default.png", "motion-diffuse.png")
manifest = {
    "schema": 1,
    "fixture_sha256": fixture_hash(),
    "producer": {
        "version": bpy.app.version_string,
        "version_tuple": list(bpy.app.version),
        "build_hash": bpy.app.build_hash.decode(),
        "platform": sys.platform,
        "engine": "CYCLES",
        "device": "CPU",
    },
    "motion_face_points": camera_face_points(scene),
    "files": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in files},
}
(output / "reference.json").write_text(json.dumps(manifest, indent=2))
print("ANDROID_RENDER_REFERENCE_COMPLETE", json.dumps(manifest), flush=True)