# Blender 5.3 final Android update

Date: 2026-11-10
Status: integrated and validated on the S24 Ultra, in `cbd1c14e6`.

## Verified source and baseline

- Official tag: `v5.3.0`, commit `02f0899d78e374b63e7181d9061e1f7ab03419cc`.
- Fork HEAD before the update: `7564bb7fa`. Last complete upstream anchor: `fefcb557`,
  synthetic parent `b28ade62`; 543 upstream commits since it.
- Official version 5.3.0, release cycle, file subversion 31 (the fork was at 29). A
  subversion change needs `build.py --reconfigure`: the fast path swaps `libblender.so`
  and leaves `makesdna`/`makesrna` behind, and the mismatch kills the process before
  `android_main` logs anything.
- Device: Samsung SM-S928B (S24 Ultra), Adreno 750.

## How the result was checked against upstream rather than assumed

A conflict-free merge is not evidence. The integrated tree was diffed against `v5.3.0`
file by file:

- Every file the update adds is byte-for-byte identical to the official tag, including
  `intern/ktx_bridge/` (seven files, upstream's own), `ktx_asan.diff`,
  `openimageio_psd.diff`, both glTF KTX modules and `az.po`.
- `build_files/build_environment/cmake/versions.cmake` has no fork delta at all, so the
  KTX 4.4.2, pip 26.2.2, certifi 2026.10.19 and Brotli 1.0.10 pins are upstream's.
- Divergence from the tag fell from 8342 files to 135 real content differences, all in
  files this port owns: GHOST Android, the Vulkan backend, EEVEE, the touch interface,
  the window manager and the Android build files. The remaining 7319 absences are
  `tests/files`, which this checkout does not fetch.

## The restructuring that required adapting code

The final release removes `VKImageView::~VKImageView`'s call to `discard_image_view` and
registers views with the resource tracker instead. Views are then retired in
`VKDiscardPool::discard_resources` or directly during swapchain cleanup. The port
invalidated its classic-render-pass framebuffer cache **only** in `discard_image_view`,
so a textual merge would have kept the hook and bypassed it at runtime, leaving stale
cached framebuffers pointing at recycled view handles -- a GPU hang on Adreno.

`VKRenderPassFallback::take_framebuffers_for_view()` is now called from all three
retirement paths. It removes the entries as it returns them, so a framebuffer is retired
once no matter how many paths see the view. Lock order is one-directional: the fallback
cache's mutex is never held while calling into the discard pool, and the cache never
calls back into it. `discard_resources` retires at the submission's own timeline rather
than the pool's default one; the completed swapchain path destroys framebuffers directly,
before the view they reference.

Preserved on top of the update: Qualcomm SPIR-V 1.3, the dynamic-vertex-input disable that
fixed EEVEE motion lighting, `graphics_pipeline_library` off on Android, the CPU
subdivision fallback, the skipped dispatch for refused pipelines, the EEVEE
`SPHERE_PROBE_REMAP_GROUP_SIZE` of 16 with its matching parallel-sum loop count of 8, the
64 MB EEVEE shadow pool cap, the Cycles SVM `memcpy` serialization, the grid shader's
explicit component selection and the touch, keymap, menu-scale and S Pen work.

## KTX for ARM64, and the overread it exposed

5.3 adds a KTX bridge for glTF (Basis Universal textures). The library was not in the port,
so it was cross-compiled: `libktx.so` for arm64-v8a, API 31, with upstream's own
`ktx_zstd_dep_fix.diff` and `ktx_asan.diff`.

Encoding then aborted the process on the device, while the same test passed on official
desktop Blender 5.3.0:

```
FORTIFY: memchr: prevented 17-byte read from 12-byte buffer
```

KTX's own `strnstr()` in `lib/writer2.c` bounds the search for the **needle's** terminator
by the length of the **haystack**. `appendLibId()` calls it with the 12-byte literal
`"__default__"` and a length of 17 -- `strlen("Unidentified app") + 1`, the value used
whenever there is no `KTXwriter` entry, which is every file this bridge writes. Android's
FORTIFY `memchr` aborts on the read; glibc merely reads adjacent memory and gets away with
it, which is why no desktop build ever noticed. Upstream's `ktx_asan.diff` does not touch
this file.

`ktx_strnstr_needle_bounds.diff` measures the needle with `strlen`, returns the haystack
for an empty needle and `NULL` when the needle cannot fit -- which also removes an
unsigned underflow in the original loop bound when the needle was longer than `len`.

## Validation

Host: 12 release-validator tests pass. Official desktop Blender 5.3.0 generated the render
and KTX references independently; 12 official Python suites (401 tests) pass there.

Mandatory release gate, `blender-full-20261110-211729-6d26b11b.apk`:

| Check | Result |
| --- | --- |
| Nine Cycles renders (one cold, eight after viewport updates) | ROI error 1.513e-08, worst row 4.087e-08, mean linear 0.2044896185 -- tolerance 0.001 |
| EEVEE final render | ROI error 1.147e-03, worst row 3.368e-03 |
| EEVEE live orbit, 40 s | 30 distinct captures over 37.82 s spanning 0.6900 rad, worst face error 0.003922 -- limit 0.100 |

On-device Python, 14 of 14 suites: the 12 official `bl_pyapi_*` suites (401 tests),
`upstream_regressions` (6 checks) and `android_final_regressions` (7 tests, including 128
offscreen framebuffer create/destroy cycles with pixel readback, which is what the view
retirement change above had to survive, and KTX encode/decode plus glTF import of official
ETC1S and UASTC fixtures).

Two defects in the new test code were fixed rather than worked around:

- `python_test_runner.py` unpacked everything after `--` into two names. The native
  launcher appends `--disable-crash-handler` after the arguments from
  `blender_args.txt`, so every suite died with `ValueError: too many values to unpack`
  and was recorded as a timeout.
- `test_full_build_features` asserted `codec_avi`. Upstream dropped the AVI codec;
  official desktop 5.3.0 reports it `False` too, so the assertion failed on a correct build.

## Coverage limits

Physical input (pen tilt, Bluetooth keyboards, multi-touch gestures) was not re-exercised
for this update. The render gate uses an unsaved factory cube; complex scenes at production
sampling are outside it. The KTX fixtures are 8x8 textures. No user data was cleared and no
preferences or projects were saved during any run.

## Known build-base trap

`deps/build.sh` and `build.py` locate the dependency prefix by looking for
`lib/android_arm64`. An abandoned tree at `/root/blender_build_android` from August can win
that search once anything creates that directory inside it, and the build then fails far
away from the cause (`Could NOT find JPEG`). Pass `BUILD_BASE=/root/blender_android_deps`
to `deps/build.sh` and `--build-base /root/blender_android_deps` to `build.py` when in
doubt.
