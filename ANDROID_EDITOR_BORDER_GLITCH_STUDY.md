# Colored pixels between editors on Android

Investigation: 2026-10-29. Device: Galaxy S24 Ultra (SM-S928B).

Scheduled release: Beta 2.

## Report and observations

The supplied screenshot shows small blue and magenta segments in the thin gap
below the top bar, above the 3D View header. The user also reports artifacts
between other editors. The first screenshot is 2245 x 1080; chromatic pixels
are concentrated in rows 68-73. These are outside the scene and occur in the
window composition, not just in the 3D render.

Fresh captures of the existing installation at 2340 x 1080 did not reproduce
the colored pixels, including after portrait/landscape rotation. The original
symptom is therefore intermittent in this test session. Absence in a new build
alone cannot prove that this specific report is resolved.

## Rendering path

1. `VKContext::sync_backbuffer()` in
   `source/blender/gpu/vulkan/vk_context.cc` creates the `back-left` color
   texture with a null initial-data pointer when its size or format changes.
2. `wm_draw_window_onscreen()` in
   `source/blender/windowmanager/intern/wm_draw.cc` sets the full-window
   viewport and blits visible regions. Its window clear was disabled by
   `#if 0`, assuming every pixel would be overwritten.
3. `area_calc_totrct()` in `source/blender/editors/screen/area.cc` explicitly
   reserves a "Small gap below Top Bar", as well as editor padding.
4. `ED_screen_draw_edges()` in
   `source/blender/editors/screen/screen_draw.cc` scissors border drawing to
   the bounds of the regular screen areas; global areas are not included.
   Borders and outlines use alpha blending.
5. `gpu_shader_area_borders.bsl.hh` outputs a uniform theme color and modifies
   its alpha for antialiasing. Even a correctly colored fragment can blend
   with undefined destination pixels if the background has never been painted.

The missing background initialization is a concrete rendering defect and a
plausible cause of the supplied artifact. Neither the image nor the source
inspection establishes a Qualcomm driver defect. There is no evidence here
that texture files, scene materials, or touch hit testing are responsible.

Vulkan does not promise defined contents for an undefined image layout:
[VkImageLayout specification](https://docs.vulkan.org/refpages/latest/refpages/source/VkImageLayout.html).
Unwritten pixels must be initialized before being displayed or used as the
destination of blending.

## Candidate correction

On Android, clear the window color buffer to `TH_EDITOR_BORDER`, with opaque
alpha, immediately after `wmWindowViewport(win)` and before region blits.
This initializes gaps and the background used by antialiased edges. The full
window scissor has already been set at that point. Offscreen region buffers
and the actual border geometry are unchanged.

The clear runs on each composition so layout changes also cannot reveal pixels
left by previous editors. It adds a full-window color clear; performance on a
tile-based GPU should be checked if redraw cost changes. A one-time clear on
allocation would not address stale pixels exposed by later layout changes.

The change is Android-only. Other platforms retain their existing behavior.

## Validation

The C++ translation unit and shared library compiled successfully. The object
file timestamp is newer than the edited source; `git diff --check` passes.
The final APK passed `apksigner verify` (v3 signature). Its embedded
`lib/arm64-v8a/libblender.so` matches the staged library byte-for-byte by SHA-256:
`f60197aead17c68cd20846aeadea47039eac45ed1be5b805deef0ebfeac5748a`.

APK: `/root/blender_android_deps/apk/blender-full-20261029-172513.apk`.
Installed on the S24 Ultra with `adb install -r` successfully, preserving app
data. No uninstall or data clear was used.

| Device check | Result |
| --- | --- |
| Startup | App remained running; initial screen and editors rendered |
| Landscape, 2340 x 1080 | No blue/magenta artifacts observed in separators |
| Portrait, 1080 x 2340 | No blue/magenta artifacts observed in separators |
| Resize vertical viewport/Properties boundary | Boundary and exposed gap rendered normally |
| Resize horizontal viewport/Timeline boundary | Boundary and exposed gap rendered normally |
| Home, then return to Blender | App remained running; no separator artifacts observed |

An objective before/after check of the reported top gap at `(1000, 70)` is
`RGB(0, 0, 0)` before and `RGB(22, 22, 22)` after, the border theme color. This
confirms the patch reaches a previously unpainted row at the location of the
reported artifact. The supplied JPEG has 769 chromatic pixels in row 70 in the
interval `200 <= x < width - 200`, using `max(R,G,B) - min(R,G,B) >= 15`;
fresh baseline and corrected landscape captures have zero in row 70 in
that interval. The baseline was already free of the colored artifact, so this
is evidence of corrected coverage, not a controlled reproduction of the
intermittent blue/magenta symptom.

In each corrected landscape capture (normal, vertical resize, horizontal
resize), all 1940 sampled pixels of row 70 are exactly `RGB(22, 22, 22)`.

Captures are retained in the task's visualization directory as
`blender-border-before*.png` and `blender-border-after*.png`. Editor sizes and
Android rotation settings were restored after the tests. Performance was not
benchmarked, and other projects/workspaces have not been exhaustively tested.

Build environment note: the default WSL user has its home at `/home/pc1`, while
the SDK is installed at `/root/android-sdk`. The first compile succeeded but
packaging failed looking for `zipalign` under the former. The final build ran
as root with a process-local `safe.directory` setting for this checkout, so
SDK discovery and Git build metadata both worked. No global Git setting or
repository build script was changed.
