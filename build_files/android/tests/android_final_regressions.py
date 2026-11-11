# SPDX-FileCopyrightText: 2026 Blender Authors
# SPDX-License-Identifier: GPL-2.0-or-later
"""Additional Android resource lifetime and feature-preservation checks."""
import gc
import importlib
import math
import unittest
import bpy
import gpu
from gpu_extras.batch import batch_for_shader
from mathutils import Matrix

class AndroidFinalTests(unittest.TestCase):
    def test_final_version(self):
        self.assertEqual(bpy.app.version, (5, 3, 0))
        self.assertEqual(bpy.app.version_cycle, 'release')

    def test_full_build_features(self):
        # No codec_avi: upstream dropped the AVI codec, and official desktop 5.3.0
        # reports it False too, so asserting it here fails on a correct build.
        for name in ('cycles', 'openimageio', 'openvdb', 'alembic', 'usd', 'ffmpeg',
                     'mod_fluid', 'mod_oceansim', 'bullet', 'international'):
            if hasattr(bpy.app.build_options, name):
                with self.subTest(feature=name):
                    self.assertTrue(getattr(bpy.app.build_options, name))

    def test_python_dependencies(self):
        for name in ('numpy', 'ssl', 'sqlite3', 'pip', 'certifi'):
            with self.subTest(module=name):
                importlib.import_module(name)
        import ssl
        self.assertGreater(ssl.create_default_context().cert_store_stats()['x509_ca'], 0)

    def test_subdivision_evaluation(self):
        mesh = bpy.data.meshes.new('AndroidTestMesh')
        mesh.from_pydata([(-1,-1,0),(1,-1,0),(1,1,0),(-1,1,0)], [], [(0,1,2,3)])
        obj = bpy.data.objects.new('AndroidTestObject', mesh)
        bpy.context.scene.collection.objects.link(obj)
        try:
            modifier = obj.modifiers.new('Subdivision', 'SUBSURF')
            modifier.levels = 2
            bpy.context.view_layer.update()
            evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
            result = evaluated.to_mesh()
            try:
                self.assertGreater(len(result.vertices), 4)
                self.assertTrue(all(math.isfinite(v) for vertex in result.vertices for v in vertex.co))
            finally:
                evaluated.to_mesh_clear()
        finally:
            bpy.data.objects.remove(obj, do_unlink=True)
            bpy.data.meshes.remove(mesh)

    def test_recycled_framebuffers_and_views(self):
        shader = gpu.shader.from_builtin('UNIFORM_COLOR')
        batch = batch_for_shader(shader, 'TRIS', {'pos': [(-1,-1,0),(3,-1,0),(-1,3,0)]})
        for index in range(128):
            width, height = ((31,29),(64,64),(97,71),(128,32))[index % 4]
            offscreen = gpu.types.GPUOffScreen(width, height)
            expected = (index % 7 / 6, index % 5 / 4, index % 3 / 2, 1)
            try:
                with offscreen.bind(), gpu.matrix.push_pop():
                    gpu.matrix.load_identity()
                    gpu.matrix.load_projection_matrix(Matrix.Identity(4))
                    fb = gpu.state.active_framebuffer_get()
                    fb.clear(color=(0,0,0,1))
                    shader.bind()
                    shader.uniform_float('color', expected)
                    batch.draw(shader)
                    actual = fb.read_color(width//2, height//2, 1, 1, 4, 0, 'FLOAT').to_list()[0][0]
                    for a,b in zip(actual,expected):
                        self.assertAlmostEqual(a,b,delta=0.01,msg=f'iteration {index}: {actual} != {expected}')
            finally:
                offscreen.free()
            if index % 8 == 0:
                gc.collect()

    def test_ktx_official_fixtures_and_gltf_import(self):
        import hashlib
        import json
        from pathlib import Path
        from types import SimpleNamespace
        import numpy as np
        from io_scene_gltf2.io.imp.gltf2_io_ktx import KtxDecoder
        fixtures = Path(__file__).parent / 'ktx-fixtures'
        manifest = json.loads((fixtures / 'manifest.json').read_text())
        self.assertEqual(manifest['build_hash'], '02f0899d78e3')
        for filename, checksum in manifest['files'].items():
            self.assertEqual(hashlib.sha256((fixtures / filename).read_bytes()).hexdigest(), checksum)
        for name in ('etc1s', 'uastc-zstd'):
            with self.subTest(format=name):
                width, height, pixels = KtxDecoder.decode_file(SimpleNamespace(), fixtures / (name + '.ktx2'))
                self.assertEqual((width, height), (8, 8))
                expected = np.tile(manifest['expected_rgba'], 64)
                self.assertLess(float(np.max(np.abs(np.array(pixels) - expected))), 0.06)
                before = {kind: set(getattr(bpy.data, kind)) for kind in ('objects', 'meshes', 'materials', 'images')}
                try:
                    self.assertEqual(bpy.ops.import_scene.gltf(filepath=str(fixtures / (name + '.gltf'))), {'FINISHED'})
                    imported = set(bpy.data.objects) - before['objects']
                    self.assertTrue(any(obj.type == 'MESH' and len(obj.data.vertices) == 3 for obj in imported))
                    images = set(bpy.data.images) - before['images']
                    self.assertTrue(any(tuple(image.size) == (8, 8) and image.has_data for image in images))
                finally:
                    for kind in ('objects', 'meshes', 'materials', 'images'):
                        collection = getattr(bpy.data, kind)
                        for item in set(collection) - before[kind]:
                            collection.remove(item, do_unlink=True)

    def test_ktx_android_encode_decode(self):
        from pathlib import Path
        from types import SimpleNamespace
        import tempfile
        import numpy as np
        from io_scene_gltf2.io.exp.ktx import KtxEncoder
        from io_scene_gltf2.io.imp.gltf2_io_ktx import KtxDecoder
        pixels = np.tile(np.array([0.25, 0.5, 0.75, 1], dtype=np.float32), 64)
        with tempfile.TemporaryDirectory(prefix='android-ktx-test-') as directory:
            for uastc, compression in ((False, 0), (True, 3)):
                with self.subTest(uastc=uastc, zstd=compression):
                    path = Path(directory) / 'roundtrip.ktx2'
                    self.assertEqual(KtxEncoder.encode_file({}, path, pixels, 8, 8, 4, quality=128,
                                                           is_data=True, use_uastc=uastc, compress=compression), 0)
                    width, height, decoded = KtxDecoder.decode_file(SimpleNamespace(), path)
                    self.assertEqual((width, height), (8, 8))
                    self.assertLess(float(np.max(np.abs(np.array(decoded) - pixels))), 0.06)
