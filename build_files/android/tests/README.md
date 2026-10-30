# Android render gate before full releases

Every full release must use build.py --release. Normal build/fastdeploy APKs are
development artifacts and have no render approval. Only a passing exact signed
candidate is copied into $BUILD_BASE/apk/releases with matching .render-check.json.
Failed, missing or incomplete checks return nonzero and create no new release APK.

## Independent official reference

Use official desktop Blender of the same major/minor version as the Android APK:

    /path/to/official/blender --background --factory-startup \
      --python build_files/android/tests/create_render_reference.py \
      -- /path/to/render-reference

On Windows use native backslash UNC paths for scripts in WSL: Blender interprets
a leading // as a Blender-relative path.

Keep references outside the checkout. reference.json records the official Blender
build hash, CPU engine, fixture hash and output checksums. Never generate the
reference from the Android candidate to make it pass. A changed fixture requires
regenerating the reference with official Blender.

## Release command

The host needs Python 3.10+, adb and ffmpeg; no extra Python packages. PATH or
ADB/FFMPEG select executables. The Windows SDK and WinGet FFmpeg are detected from
WSL when available. The named device must stay unlocked, in Blender, in the same
orientation during capture.

    python3 build_files/android/build.py full --release \
      --render-reference /path/to/render-reference -s DEVICE_SERIAL

This forces runtime repackaging and owns installation/testing. It cannot be
combined with debug/validation builds or competing device actions. Device data is
preserved by install -r. Tests never clear data, uninstall, save preferences or
save a project. They start an unsaved factory scene: finish any current work first.
Existing external launch arguments are restored after success or failure.

To check an archived APK without building/promoting it:

    python3 build_files/android/tests/run_render_regressions.py \
      --apk /path/to/blender-full.apk --reference /path/to/render-reference \
      --output /path/to/a-new-report-directory -s DEVICE_SERIAL

The output directory must be new, preventing stale approval. APK SHA-256,
reference provenance, render metrics, screenshots and device output are retained.
Changing APK bytes invalidates the approval.

## Required checks

* Nine Cycles CPU renders: a cold render and eight after viewport updates.
  Compare full linear RGB, cube ROI and worst ROI row with the official reference.
  ROI tolerance 0.001 also rejects the zeroed-stack diagnostic (error 0.00235).
* EEVEE final render compared with the same CPU reference using separate tolerances
  for normal engine/sampling differences.
* A 40-second live EEVEE orbit of a diffuse cube. Projected centers of three faces
  are sampled from the composed Android screen while the view keeps moving.
  Compare display RGB with the official CPU rendering. At least 24 distinct motion
  samples must span 30 seconds and 0.60 radians. Any sampled face error >= 0.10
  blocks release. Capturing only after motion stops cannot pass.
* Reference/fixture checksums, complete output, matching candidate APK checksum.
  Missing tools/reference/device, crashes, timeouts, missing capture or failed
  evidence collection block approval.

This gate covers the two known regressions on the tested device/driver. It is not
exhaustive coverage of all scenes, materials, GPUs or drivers. Validate each intended
device/driver; one device's pass is not universal compatibility.
Lite omits Cycles and is not accepted by this full gate.

## Validate the gate

    python3 -m unittest discover -s build_files/android/tests \
      -p test_release_validation.py -v

Host tests cover failed/incomplete results, uniform face lighting, missing motion,
changed APK bytes, missing prerequisites, Python -O and build/gate ordering.

Also test a known-bad APK when changing the gate. On the S24 Ultra on 2026-10-29,
blender-full-20261029-183530.apk was rejected: all nine Cycles checks failed and
EEVEE motion reached error 0.32549. Its static EEVEE final render passed,
demonstrating why motion testing is mandatory.
