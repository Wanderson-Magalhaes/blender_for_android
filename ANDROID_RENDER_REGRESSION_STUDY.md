# EEVEE motion lighting and Cycles shading regressions — 2026-10-29

## Scope and device

Investigated on Samsung SM-S928B (S24 Ultra), Adreno 750, Qualcomm driver build
`bb11e2f361` dated 2026-07-24. Source base: `ebe4f49e5`, with the existing local
work retained. The user supplied cube/astronaut screenshots and a recording
showing EEVEE lighting switching while the view rotates.

Two separate rendering paths were implicated. The 18 upstream stability
backports remain applied. Their introduction was initially suspected, but an
introducing commit was not established by bisection; do not describe this as
a proven regression from that batch.

## EEVEE: Qualcomm dynamic vertex input

Capturing only after the camera stopped missed the reported defect. A timer
was changed to orbit continuously, requesting redraws about every 30 ms, and
the composed Android surface was recorded for 12 seconds per case. The cube
repeatedly switched between correct face lighting and almost uniform shading
while moving. The user's recording shows the same behavior.

| Continuous-motion configuration | Observed result |
| --- | --- |
| Normal backend | Abrupt lighting changes reproduced |
| Temporal reprojection off | Defect remained |
| Light shadows off | Defect remained |
| Texture-pool memory aliasing disabled | Defect remained |
| Previous streaming-buffer implementation, diagnostic APK | Did not resolve the EEVEE defect; restored afterward |
| All GPU workarounds forced | Stable lighting |
| Only dynamic vertex input disabled | Stable lighting |
| Final build, no diagnostic GPU flags | Stable lighting |

A temporary feature-isolation build confirmed the narrow configuration in its
startup log: `value=7016 dyn=1 vin=0 multi=1 layer=1 local=0 unused=0`. In
particular, extended dynamic state and multi-draw stayed enabled. Diagnostic
code and debug-value switches were removed from the final source and APK.

`VKBackend::detect_workarounds()` now disables
`extensions.vertex_input_dynamic_state` for Qualcomm devices on Android.
Vertex input is described statically by each graphics pipeline instead. The
same class of workaround already existed for Qualcomm on Windows, referencing
upstream issue #153414. Other vendors and other operating systems retain their
previous behavior. This does not force all GPU workarounds or disable EEVEE,
shadows, reprojection, texture pooling or the Qualcomm tile-memory extension.

## Cycles: packed SVM fields lost during serialization

The cause is in `intern/cycles/scene/svm.h`, before the CPU kernel executes.
`SVMCompiler::add_node()` and `add_node_data()` reinterpreted a node struct as an
`int *`. Optimized NDK Clang builds did not reliably preserve stores to packed
byte-sized stack offsets. This violates strict aliasing; Vulkan and Embree are
not responsible.

A shader-stack sentinel probe measured actual reads before writes. In the factory
cube's Principled BSDF (shader 7, node type 2, stream offset 135), slots 113, 114
and 115 were read without a preceding write. A separate field probe showed:

| Serialization | Normal offset | Tangent offset | Coat-normal offset |
| --- | ---: | ---: | ---: |
| Original casts | 113 | 94 | 69 |
| Byte copy | 0 | 255 (invalid/unlinked) | 0 |

The correct normal uses slot 0, written by the preceding geometry node.
Zeroing the stack only masked corruption: a zero normal triggers a geometric
normal fallback. That masked render's ROI mean was 0.20214391, different from the
official reference 0.20448962. Filling the stack with -12345 made the invalid
reads visible and intentionally darkened the diagnostic render.

The fix reads each word using `std::memcpy` from the struct's character object
representation. `add_node()` calls the same `add_node_data()` serializer.
The packed stream format, node scheduling and render options are unchanged.
No Android-specific kernel workaround or global compiler flag is needed.

### Introducing source change

The upstream history was shallow. After progressively deepening the history
rooted at `7f49bbe11`, a pickaxe search and parent comparison located
`7ee94c067cf71845727672ed77dc25f088cd5b32`, 2026-04-09:
**Refactor: Cycles: Replace uint4 SVM packing with structs**, upstream PR #156612.
It adds both invalid `reinterpret_cast<const int *>` serialization loops;
its parent uses the explicit uint4 packing API.

The same loops are in the first Android commit `897d6548c` (2026-08-21), the
recovered anchor `2a46ee30b` and Beta snapshot `b28ade629`.
The introducing source change is identified. The first visibly affected APK is
not established by binary bisection: optimization/code-layout changes can expose
older undefined behavior. Do not attribute this to the 18 backports or EEVEE fix.

### Rejected hypotheses and verification

| Diagnostic | Result |
| --- | --- |
| BVH2 instead of Embree | Extended sequences failed; fallback removed |
| One render thread; worker index and FPCR logging | Failed with valid measured worker/FP state |
| Initialize main integrator state or surface ShaderData | Failed |
| Initialize optional kernel structs | Failed |
| Auto-initialize locals up to 8 or 16 bytes | Failed |
| Auto-initialize all kernel locals | Stable, but masks invalid SVM stack data |
| Initialize only SVM stack | Nine stable renders, ROI error 0.00234598; masks corrupted normal |
| Sentinel stack with original serializer | Invalid reads logged; ROI mean 0.01189006 |
| Sentinel stack with byte-copy serializer | No invalid reads; nine renders with ROI error 3.75e-8 |
| Final byte-copy build, all probes/initialization removed | Nine identical renders with ROI error 3.75e-8 |

Production APK: `blender-full-20261029-221227.apk`. Installed in place on the
S24 Ultra; user data was not cleared. The final run includes one cold CPU render,
a 12-second EEVEE orbit (322 redraw requests), an EEVEE final render and eight CPU
renders after Cycles viewport updates. All ten checks pass. The nine Cycles renders
have ROI mean 0.2044896185 and mean absolute linear RGB error 3.746987e-8 against
the official Blender 5.3 Beta reference. Saved PNGs were visually inspected.
`production-motion.mp4` and its contact sheet show stable lighting during the
recorded movement and viewport updates.

The EEVEE patch was preserved byte for byte (diff SHA-256:
`06fd82f492ae0624f5605b50c8306ea585aa4d054d7e696014cbdfdd98fe823e`).
No auto-initializer flags, sentinel fills, thread-local probes or native diagnostic
logging remain in Cycles production source.

The initial device-only test was replaced by the release gate below. It uses
an unsaved factory cube and never saves projects or preferences.

The initial native reference (ROI 0.1653189) was itself wrong; it is not a healthy
reference. Older reports retain obsolete labels as diagnostic evidence.
Astronaut/complex-scene testing at adequate sampling is outside this completed
cube regression's coverage.

## Required release regression gate

`build.py full --release --render-reference DIR -s SERIAL` repackages and freezes
the candidate APK, then runs `run_render_regressions.py` before promotion into
`apk/releases`. Official desktop Blender generates an independent reference;
fixture/output hashes are checked. Cycles ROI tolerance 0.001 now rejects even
the zero-stack diagnostic (error 0.00235), and worst-row metrics catch bands.

EEVEE uses a Lambertian cube during a 40-second continuous orbit. The host samples
the projected centers of +X, -Y and +Z faces from composed Android screenshots and
compares display RGB with the official CPU image. At least 24 distinct samples,
30 seconds of coverage and 0.60 radians of travel are required. A sampled face
error >= 0.10 blocks release.

The known-bad `blender-full-20261029-183530.apk` was rejected: its EEVEE final
render passed, but motion failed with errors up to 0.325490 (27 captures over
37.02 seconds), and all nine Cycles renders failed. This control demonstrates that
static EEVEE checks alone would have let the old defect through.
The independent reference used official Blender build `1878423c3717`.

Missing prerequisites, timeouts, crashes, missing frames, incomplete output and
APK hash mismatch fail closed. Only approved APK bytes and matching JSON evidence
enter `apk/releases`. See `build_files/android/tests/README.md` for commands
and device/scene coverage limits.

### Complete release-command validation

The real build/repackage/test/promote path passed on the S24 Ultra.
Approved APK: blender-full-20261030-014605-687ec04f.apk (UTC filename).
The EEVEE orbit supplied 31 distinct captures over 37.23 seconds, spanning 0.6999
radians; worst face error was 0.007844 against the 0.10 limit. All nine Cycles
checks and the EEVEE final render passed. The promoted APK SHA-256 was rechecked:
687ec04f4009fc5bf5827828b5b98dca490fe0e20d56bf59e361975a359e64a8.
Twelve host tests passed, including the guard that rejects --render-reference
without --release. Only this APK and matching JSON evidence were promoted.

## Implementation commits

- Cycles serialization fix: `8269e1e45`.
- Qualcomm EEVEE workaround: `7809c5374`.
- Full release gate: `177c1de6c`.
- Diagnostic launch support: `c0edd3a2f`.
