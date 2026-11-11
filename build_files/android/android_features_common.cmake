# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Feature toggles shared by BOTH Android configs (lite and full). The
# config-specific files include this, then set the heavy features. Used by the
# host codegen-tools build (cmake -C) and platform_android.cmake, so generated
# RNA/DNA matches the target feature set.

# Desktop-only / unused on Android.
set(WITH_INPUT_NDOF OFF CACHE BOOL "" FORCE)
set(WITH_XR_OPENXR OFF CACHE BOOL "" FORCE)
set(WITH_JACK OFF CACHE BOOL "" FORCE)
set(WITH_PULSEAUDIO OFF CACHE BOOL "" FORCE)
set(WITH_SDL OFF CACHE BOOL "" FORCE)
set(WITH_OPENAL OFF CACHE BOOL "" FORCE)
set(WITH_OPENMP OFF CACHE BOOL "" FORCE)
set(WITH_HYDRA OFF CACHE BOOL "" FORCE)
set(WITH_GMP OFF CACHE BOOL "" FORCE)
set(WITH_CODEC_SNDFILE OFF CACHE BOOL "" FORCE)
# Draco-compressed glTF. The dependency is not cross-compiled yet;
# see ANDROID_MISSING_FEATURES.md.
set(WITH_DRACO OFF CACHE BOOL "" FORCE)
# New in 5.3, and not cross-compiled for Android yet: Jolt Physics, and
# OpenTimelineIO for the sequencer's .otio import/export. Both default ON
# upstream and would fail the build without their libraries.
set(WITH_JOLT OFF CACHE BOOL "" FORCE)
set(WITH_OPENTIMELINEIO OFF CACHE BOOL "" FORCE)

# Open Image Denoise needs TBB, which the lite config drops, so it is enabled
# per-config rather than here: OFF is the default, full turns it back on.
set(WITH_OPENIMAGEDENOISE OFF CACHE BOOL "" FORCE)

set(WITH_OPENCOLLADA OFF CACHE BOOL "" FORCE)
set(WITH_TRACY OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_OSL OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_CUDA OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_OPTIX OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_HIP OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_DEVICE_ONEAPI OFF CACHE BOOL "" FORCE)
set(WITH_CYCLES_CUDA_BINARIES OFF CACHE BOOL "" FORCE)

# Core features present in every Android build.
set(WITH_PYTHON ON CACHE BOOL "" FORCE)
set(WITH_OPENIMAGEIO ON CACHE BOOL "" FORCE)
set(WITH_OPENSUBDIV ON CACHE BOOL "" FORCE)
set(WITH_TBB ON CACHE BOOL "" FORCE)
set(WITH_HARFBUZZ ON CACHE BOOL "" FORCE)
set(WITH_FRIBIDI ON CACHE BOOL "" FORCE)
set(WITH_POTRACE ON CACHE BOOL "" FORCE)
set(WITH_IO_WAVEFRONT_OBJ ON CACHE BOOL "" FORCE)

# The glTF KTX bridge is a runtime library, not a code-generator dependency.
# Native host generators do not load it; the Android target ships ARM64 KTX.
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
  set(WITH_KTX ON CACHE BOOL "" FORCE)
else()
  set(WITH_KTX OFF CACHE BOOL "" FORCE)
endif()
