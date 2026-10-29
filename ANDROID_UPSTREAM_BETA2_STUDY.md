# Blender 5.3 stability backports for Android Beta 2

Reviewed on 2026-10-29 using `blender-v5.3-release` at
`fb11a08147140eac42dcee76eed70ff59a7fcd8f`. There are 377 commits since the
last complete sync, `fefcb55798488e87fbcac1460d86384dbde3a242` (2026-10-14).
This is a selective backport, not a complete sync to the reviewed tip.
The last-full-sync anchor and synthetic parent remain unchanged.

## Included fixes

18 upstream patches, 20 source/test files, 151 insertions and 48 deletions.
All applied without conflicts against the fork. No DNA, file subversion,
dependency version, runtime payload, or build feature setting was changed.
The GPU vertex buffer fix includes its matching OpenGL/Metal bounds checks
to keep the shared API contract consistent; Android still builds Vulkan.

| Upstream commit | Correction |
| --- | --- |
| [`973e687d6`](https://projects.blender.org/blender/blender/commit/973e687d697ed57d5500a0fe18c1769cf25a15a0) | Fix: Vulkan: Invalid pipelines with static viewport workaround |
| [`698d3cbbc`](https://projects.blender.org/blender/blender/commit/698d3cbbc76201bee7c4ebf4d9df87c2945bbfcf) | Fix: Vulkan clip distance emulation breaks with injected geometry shader |
| [`7bf8f7651`](https://projects.blender.org/blender/blender/commit/7bf8f76518e92d2b956fee6abac7c835ff1cffb7) | Fix: Vulkan: Index buffer rebind skipped when resource handle is 0 |
| [`272b114d0`](https://projects.blender.org/blender/blender/commit/272b114d07b0a5a2a965bcc203dc6fefcbe265d4) | Fix #164024: Changing area type from file selector crashes |
| [`57479d3fc`](https://projects.blender.org/blender/blender/commit/57479d3fce2352e2326e1e762f7ef17d37c25ece) | Fix: VVL error in VKStreamingBuffer |
| [`333093a2f`](https://projects.blender.org/blender/blender/commit/333093a2f9bb3a833b768bd44cd272d9ca9d2c80) | Fix: Vulkan: Buffer allocations no longer padded to 16 bytes |
| [`1b770b5f2`](https://projects.blender.org/blender/blender/commit/1b770b5f2198ff3f7a86446ce69429e5036a7b34) | Fix: potential buffer overflow in RNA_property_string_get_default |
| [`86451aae7`](https://projects.blender.org/blender/blender/commit/86451aae7e55491ad8e12929fbff66b0d85d5ce6) | Fix: stack buffer overflow regression comparing long override RNA paths |
| [`c69c8b233`](https://projects.blender.org/blender/blender/commit/c69c8b23314cf1bc34752c623ed65e33d5f1e6d3) | Fix: stack buffer overflow flipping actions with long bone names |
| [`ac21e0c0c`](https://projects.blender.org/blender/blender/commit/ac21e0c0c41bdb3d013ef9a24220cf94b91e808a) | Fix: buffer overflow inserting invalid UTF8 text into a text object |
| [`39f97750a`](https://projects.blender.org/blender/blender/commit/39f97750aff91ee8ef1863b8991391ca34131694) | Fix: buffer overflow adding frame digits to long paths |
| [`ccbc85363`](https://projects.blender.org/blender/blender/commit/ccbc8536367d435f0d58798ff64cfac7840e07c3) | Fix #165659: Crash when using the Python GPU API on startup |
| [`b6e616ea0`](https://projects.blender.org/blender/blender/commit/b6e616ea068323bf2132a18f4d79b4d5c74a8b74) | Fix: buffer overflow reading multi-layer EXR's with long pass names |
| [`dd68d6b15`](https://projects.blender.org/blender/blender/commit/dd68d6b15de84bbc07a2cf5365c5010e553fd70a) | Fix: invalid UTF8 truncating multi-layer EXR layer & pass names |
| [`b80f4bc99`](https://projects.blender.org/blender/blender/commit/b80f4bc992780095ee210c8330453c4d3a282db7) | Fix: GPU vertex buffer copy_sub bounds and Vulkan copy parameters |
| [`32854dfd6`](https://projects.blender.org/blender/blender/commit/32854dfd622ee74947e6a81a3f8b2cb075380d44) | Fix: Vulkan: Crash closing a window that has child windows |
| [`41c7de3a5`](https://projects.blender.org/blender/blender/commit/41c7de3a56d9d5718613aad5fd11fb086e532477) | Fix: GPU: Varying size point shader drawing square instead of round points |
| [`79e6381b0`](https://projects.blender.org/blender/blender/commit/79e6381b067e1b2058edbfadcd08055dac3dc91b) | Fix: GPU: Builtin shader conditions referring to non existing constants |

## Android review and exclusions

- Preserve the Vulkan render-pass fallback, its framebuffer retirement hook,
  the device-lost timeout, Qualcomm SPIR-V 1.3, mobile memory reporting,
  static viewport workaround, touch handling, menu scaling and the editor
  background correction. None was removed or replaced by an upstream file.
- `b756b72bf`: enabling separate depth/stencil layouts is already implemented
  by the port in `GHOST_ContextVK.cc`; adding it again would duplicate the
  feature structure. No extra patch is needed.
- `da78405cd`: the resource reference-counting rewrite changes 19 files and
  the discard lifecycle. It needs a separate compatibility audit of the
  Android render-pass fallback and its cached framebuffer retirement.
- `3e9bfb97c`: its image-view cache fix depends on the above rewrite. The
  current fork still owns/discards image views in `VKImageView`'s destructor;
  the upstream patch assumes a different lifetime model. It was not applied.
- Skip dependency updates, the ray-query configuration addition, backend-only
  fixes for platforms Android cannot use, and unrelated feature/UI work.
  Other 5.3 fixes remain candidates for a later reviewed batch.

## Application and provenance

The managed Windows worktree attempt failed because its post-checkout hook is
a Linux script under `NUL/`. Git removed the failed worktree; the original
checkout was retained. Patches were instead preflighted one by one in a
temporary Git index, then the reviewed combined diff was checked and applied
to the original working tree. The existing staged deletion and unrelated
working changes were preserved. Upstream SHA provenance is listed above so a
later commit can carry the equivalent of `cherry-pick -x` attribution.

## Validation

Reusable device test: `build_files/android/tests/upstream_regressions.py`.
It executes in Blender's Android process through `--python SCRIPT -- RESULT`.
The optional `native` argument runs only the path tests, suitable for the
previous APK. An intentionally larger allocation surrounds the logical
8-byte buffer with canaries, so detecting the old overflow does not write
outside the actual allocation.

On the previously installed S24 Ultra build, the frame and frame-range tests
both returned success and overwrote canary bytes beyond the declared limit.
The normal `image_0123` case passed. These are measured pre-update failures,
not inferred from source. Full-mode tests also create ordinary/clipped GPU
shaders directly during startup and draw/read back a triangle in three
offscreen sizes (including odd sizes).

The Full build completed all 400 incremental steps and produced
`blender-full-20261029-180013.apk` (235 MiB). The APK passed v3 signature
verification and installed with `adb install -r` on the S24 Ultra, retaining
application data. No version/DNA reconfiguration or payload repack was needed.

| Device regression | Previous APK | Updated APK |
| --- | --- | --- |
| Frame path logical limit / canaries | Failed: returned success, overwrote canaries | Passed: returned false, canaries unchanged |
| Frame range logical limit / canaries | Failed: returned success, overwrote canaries | Passed: returned false, canaries unchanged |
| Normal frame path formatting | Passed: `image_0123` | Passed: `image_0123` |
| Python GPU API during startup | Not run | Passed: ordinary and clipped builtin shaders |
| GPU draw, resize and pixel readback | Not run | Passed: 31x29, 64x64 and 97x71 buffers, red center and black corner |
| File/Asset Browser mode changes | Not run | Passed: FILES -> ASSETS -> FILES -> ASSETS -> FILES, restored viewport |

The last row uses the test script's `ui` mode: one transition per timer tick
allows the actual editor to redraw between switches. All six checks passed.
The JSON reports are retained with the task artifacts as `upstream-baseline.json`,
`upstream-updated.json` and `upstream-ui.json`. The startup arguments used to run
them are temporary and removed after testing.

These checks do not independently reproduce every one of the 18 upstream
regressions. In particular, invalid UTF-8 text, oversized RNA/animation paths,
malformed EXR inputs, other GPUs and the round varying-size point shader were
not exhaustively tested. The upstream C++ path unit tests are retained in the
patch, but no desktop gtest build was run; the canary cases ran against the
actual Android library instead.

Manual smoke checks confirmed portrait viewport rendering, the folded top-bar
menu and its spacing, F3 search and the on-screen keyboard opening. The phone
then switched to its Camera app while Blender remained alive; further input
was stopped rather than taking focus away. Character entry by a virtual key,
touch-drag scrolling and landscape rotation were not verified in this final
manual pass. Original Android rotation settings were restored and the test
startup arguments/results were removed from the device after local copies
were retained. No scene or preferences were saved by the test harness.
