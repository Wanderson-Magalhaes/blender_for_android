# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Platform setup for Android (arm64), consuming the harvested dependency
# prefix produced by build_files/android/deps/build.sh.
#
# WIP: establishes LIBDIR and the per-package <Pkg>_ROOT hints, and disables
# desktop-only features. Full configure is being brought up incrementally.

if(NOT DEFINED BUILD_BASE)
  # All Android build artifacts live under this sibling dir (see build_apk.sh).
  set(BUILD_BASE "${CMAKE_SOURCE_DIR}/../blender_build_android")
endif()
if(NOT DEFINED LIBDIR)
  # Harvested deps, matching the deps builder's default.
  set(LIBDIR "${BUILD_BASE}/lib/android_arm64")
endif()
if(NOT EXISTS "${LIBDIR}")
  message(FATAL_ERROR "Android LIBDIR not found: ${LIBDIR}\n"
    "Build dependencies first: build_files/android/deps/build.sh")
endif()
message(STATUS "Android LIBDIR = ${LIBDIR}")

# Feature set: -DBLENDER_ANDROID_CONFIG=lite|full (or env), default full. Must be
# set early (CROSSCOMPILE_TOOLDIR and find_package guards depend on it). Matches
# the host codegen-tools build's feature flags exactly.
if(NOT DEFINED BLENDER_ANDROID_CONFIG)
  if(DEFINED ENV{BLENDER_ANDROID_CONFIG})
    set(BLENDER_ANDROID_CONFIG $ENV{BLENDER_ANDROID_CONFIG})
  else()
    set(BLENDER_ANDROID_CONFIG full)
  endif()
endif()
message(STATUS "Android config: ${BLENDER_ANDROID_CONFIG}")
include(${CMAKE_SOURCE_DIR}/build_files/android/android_features_${BLENDER_ANDROID_CONFIG}.cmake)

# pthread/rt are folded into bionic libc; empty stubs satisfy deps that still
# emit -lpthread/-lrt (created by the deps builder in .stublibs).
foreach(_lf CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS)
  string(APPEND ${_lf} " -L${LIBDIR}/.stublibs")
endforeach()

# NDK libc++ lacks std::atomic_ref (C++20); force-include a polyfill.
string(APPEND CMAKE_CXX_FLAGS
  " -include ${CMAKE_SOURCE_DIR}/build_files/android/compat/atomic_ref_compat.hpp")

# The NDK ships older Vulkan headers; use our up-to-date Vulkan-Headers first.
include_directories(BEFORE SYSTEM ${LIBDIR}/vulkan/include)
set(VULKAN_INCLUDE_DIR ${LIBDIR}/vulkan/include)
set(VULKAN_INCLUDE_DIRS ${LIBDIR}/vulkan/include)
find_library(VULKAN_LIBRARY vulkan REQUIRED)
set(VULKAN_LIBRARIES ${VULKAN_LIBRARY})
set(VULKAN_FOUND ON)

# adrenotools: lets us load a replacement Vulkan driver (Mesa Turnip) without root.
if(EXISTS ${LIBDIR}/adrenotools/lib/libadrenotools.a)
  include_directories(SYSTEM ${LIBDIR}/adrenotools/include)
  list(APPEND VULKAN_LIBRARIES
    ${LIBDIR}/adrenotools/lib/libadrenotools.a
    ${LIBDIR}/adrenotools/lib/liblinkernsbypass.a
  )
  add_definitions(-DWITH_ADRENOTOOLS)
endif()

# Find harvested libs by rooting into their prefixes, never host paths.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BOTH)
file(GLOB _android_dep_prefixes "${LIBDIR}/*")
# These are target artifacts installed on the build host. Marking LIBDIR as the
# staging prefix prevents CMake from repeatedly prepending every dependency
# prefix to every other prefix (an O(n^2) search that made Android configure
# take tens of minutes), while the NDK sysroot remains the cross root.
set(CMAKE_STAGING_PREFIX "${LIBDIR}")
list(APPEND CMAKE_PREFIX_PATH ${_android_dep_prefixes})

# Per-package root hints for find_package().
set(ZLIB_ROOT ${LIBDIR}/zlib)
set(ZSTD_ROOT ${LIBDIR}/zstd)
set(Imath_ROOT ${LIBDIR}/imath)
set(fmt_ROOT ${LIBDIR}/fmt)
set(TBB_ROOT ${LIBDIR}/tbb)
set(OpenEXR_ROOT ${LIBDIR}/openexr)
set(PNG_ROOT ${LIBDIR}/png)
set(JPEG_ROOT ${LIBDIR}/jpeg)
set(TIFF_ROOT ${LIBDIR}/tiff)
set(WebP_ROOT ${LIBDIR}/webp)
set(Freetype_ROOT ${LIBDIR}/freetype)
set(HARFBUZZ_ROOT ${LIBDIR}/harfbuzz)
set(OpenImageIO_ROOT ${LIBDIR}/openimageio)
set(OpenColorIO_ROOT ${LIBDIR}/opencolorio)
set(OpenSubdiv_ROOT ${LIBDIR}/opensubdiv)
set(OpenVDB_ROOT ${LIBDIR}/openvdb)
set(Alembic_ROOT ${LIBDIR}/alembic)
set(MaterialX_ROOT ${LIBDIR}/materialx)
set(Embree_ROOT ${LIBDIR}/embree)
set(pxr_ROOT ${LIBDIR}/usd)
set(PYTHON_ROOT ${LIBDIR}/python)
set(LLVM_ROOT_DIR ${LIBDIR}/llvm)
set(CLANG_ROOT_DIR ${LIBDIR}/llvm)
set(SQLite3_ROOT ${LIBDIR}/sqlite)
set(Potrace_ROOT ${LIBDIR}/potrace)
set(FFMPEG_ROOT ${LIBDIR}/ffmpeg)
set(Robinmap_ROOT ${LIBDIR}/robinmap)
set(PUGIXML_ROOT ${LIBDIR}/pugixml)
set(EXPAT_ROOT ${LIBDIR}/expat)
set(yaml-cpp_ROOT ${LIBDIR}/yamlcpp)
set(Blosc_ROOT ${LIBDIR}/blosc)
set(OpenJPEG_ROOT ${LIBDIR}/openjpeg)
set(pystring_ROOT ${LIBDIR}/pystring)
set(Eigen3_ROOT ${LIBDIR}/eigen)
set(absl_ROOT ${LIBDIR}/abseil)
set(Fribidi_ROOT ${LIBDIR}/fribidi)
set(SSE2NEON_INCLUDE_DIR ${LIBDIR}/sse2neon/include)
set(LibFFI_ROOT ${LIBDIR}/libffi)
set(OpenSSL_ROOT ${LIBDIR}/openssl)
set(OpenImageDenoise_ROOT ${LIBDIR}/openimagedenoise)
set(draco_ROOT ${LIBDIR}/draco)
set(GMP_ROOT_DIR ${LIBDIR}/gmp)
set(manifold_ROOT ${LIBDIR}/manifold)
set(Ceres_ROOT ${LIBDIR}/ceres)
set(HARU_ROOT_DIR ${LIBDIR}/haru)
set(FFTW3_ROOT_DIR ${LIBDIR}/fftw3)
set(openpgl_ROOT ${LIBDIR}/openpgl)

# Vulkan surface from the NDK sysroot.
set(WITH_VULKAN_BACKEND ON)
set(WITH_GHOST_ANDROID ON)
# Global so creator.cc (GHOST_android_launch) and the GHOST backend agree.
add_definitions(-DWITH_GHOST_ANDROID)
# volk must load the Android surface entrypoint (vkCreateAndroidSurfaceKHR).
add_definitions(-DVK_USE_PLATFORM_ANDROID_KHR)

# -----------------------------------------------------------------------------
# Cross-compiled build tools (makesdna, makesrna, datatoc, msgfmt, shader_tool).
# These generate source at build time and must run on the host, so they are
# built natively (macOS arm64 == Android arm64 data model, so DNA/RNA offsets
# match) and imported here. Build them first:
#   cmake -S . -B ../build_host_tools -G Ninja -DWITH_CYCLES=OFF
#   ninja -C ../build_host_tools makesdna makesrna datatoc msgfmt shader_tool
set(WITH_CROSSCOMPILED_TOOLS ON)
if(NOT DEFINED CROSSCOMPILE_TOOLDIR)
  # Host tools are config-specific (generated code matches the feature set).
  set(CROSSCOMPILE_TOOLDIR "${BUILD_BASE}/build_host_tools_${BLENDER_ANDROID_CONFIG}/bin")
endif()
foreach(_tool makesdna makesrna datatoc msgfmt shader_tool)
  if(NOT EXISTS "${CROSSCOMPILE_TOOLDIR}/${_tool}")
    message(FATAL_ERROR "Host tool missing: ${CROSSCOMPILE_TOOLDIR}/${_tool}\n"
      "Build host tools first (see platform_android.cmake header).")
  endif()
  add_executable(${_tool} IMPORTED GLOBAL)
  set_property(TARGET ${_tool} PROPERTY IMPORTED_LOCATION "${CROSSCOMPILE_TOOLDIR}/${_tool}")
endforeach()

# Desktop-only or not-yet-ported features: keep off for Android.
set(WITH_GHOST_X11 OFF)
set(WITH_GHOST_WAYLAND OFF)
set(WITH_GHOST_SDL OFF)
set(WITH_X11 OFF)
set(WITH_OPENGL_BACKEND OFF)
set(WITH_GHOST_XDND OFF)
set(WITH_COREAUDIO OFF)

# Feature toggles that vary by config (WITH_CYCLES, WITH_USD, WITH_OPENVDB, …)
# live in build_files/android/android_features_{common,full,lite}.cmake, included
# near the top of this file. Do NOT re-set them here: a normal variable would
# shadow the cache and break the lite config. Only Android-invariant extras below.
set(WITH_LIBMV_SCHUR_SPECIALIZATIONS OFF)
set(WITH_PYTHON_INSTALL OFF)
set(WITH_PYTHON_MODULE OFF)
set(WITH_DOC_MANPAGE OFF)
# Offline GLSL-as-C++ shader validation (dev feature); libc++ name clashes
# (e.g. hypot). Runtime shaders still compile via shaderc.
set(WITH_GPU_SHADER_CPP_COMPILATION OFF)
set(WITH_CYCLES_HYDRA_RENDER_DELEGATE OFF)


# -----------------------------------------------------------------------------
# Locate the harvested dependencies (mirrors platform_unix for our subset).

macro(find_package_wrapper)
  find_package(${ARGV})
endmacro()

# Search the host PATH only. Every dependency prefix is on CMAKE_PREFIX_PATH and
# one of them, ${LIBDIR}/python/bin, holds the *Android* interpreter; picking that
# one makes the first codegen script (discover_nodes.py) fail with
# "Exec format error". NO_CMAKE_FIND_ROOT_PATH alone does not exclude it.
find_program(HOST_PYTHON_EXECUTABLE NAMES python3.13 python3 python
  NO_CMAKE_FIND_ROOT_PATH NO_CMAKE_PATH NO_CMAKE_SYSTEM_PATH
  NO_CMAKE_ENVIRONMENT_PATH NO_PACKAGE_ROOT_PATH)
if(NOT HOST_PYTHON_EXECUTABLE)
  message(FATAL_ERROR "No host python3 found for build-time scripts")
endif()
set(PYTHON_EXECUTABLE "${HOST_PYTHON_EXECUTABLE}" CACHE FILEPATH "" FORCE)

find_package_wrapper(JPEG REQUIRED)
find_package_wrapper(PNG REQUIRED)
find_package_wrapper(ZLIB REQUIRED)
find_package_wrapper(Zstd REQUIRED)
find_package_wrapper(fmt REQUIRED)
find_package(Eigen3 REQUIRED)
find_package_wrapper(Freetype REQUIRED)
find_package_wrapper(Brotli REQUIRED)
find_package_wrapper(Harfbuzz)
find_package_wrapper(Fribidi)

if(WITH_PYTHON)
  set(PYTHON_VERSION 3.13)
  set(PYTHON_INCLUDE_DIR ${LIBDIR}/python/include/python3.13)
  set(PYTHON_INCLUDE_CONFIG_DIR ${LIBDIR}/python/include/python3.13)
  set(PYTHON_LIBRARY ${LIBDIR}/python/lib/libpython3.13.so)
  set(PYTHON_LIBPATH ${LIBDIR}/python/lib)
  find_package(PythonLibsUnix REQUIRED)
  # numpy (cross-compiled into the target site-packages).
  set(_np ${LIBDIR}/python/lib/python3.13/site-packages/numpy/_core/include)
  if(EXISTS ${_np}/numpy/ndarrayobject.h)
    set(WITH_PYTHON_NUMPY ON)
    set(PYTHON_NUMPY_INCLUDE_DIRS ${_np})
    set(PYTHON_NUMPY_PATH ${LIBDIR}/python/lib/python3.13/site-packages)
  endif()
endif()

find_package_wrapper(OpenEXR REQUIRED)
find_package_wrapper(OpenJPEG)
find_package_wrapper(WebP)
find_package_wrapper(PugiXML)
find_package_wrapper(TBB)
# Blender uses tbbmalloc's scalable_allocation_mode, so link it too.
set(TBB_LIBRARIES TBB::tbb TBB::tbbmalloc)
find_package_wrapper(OpenImageIO REQUIRED)
# OIIO built without tools; stub the tool target (not executed in this config).
if(NOT TARGET OpenImageIO::oiiotool)
  add_executable(OpenImageIO::oiiotool IMPORTED)
  set_target_properties(OpenImageIO::oiiotool PROPERTIES
    IMPORTED_LOCATION "${LIBDIR}/openimageio/bin/oiiotool")
endif()
find_package_wrapper(OpenColorIO 2.0.0 REQUIRED)
test_neon_support()  # sets SUPPORTS_NEON_BUILD, so Cycles uses sse2neon not -msse
find_package_wrapper(sse2neon REQUIRED)
if(WITH_OPENVDB)
  find_package_wrapper(OpenVDB)
  find_package_wrapper(NanoVDB)
endif()
if(WITH_ALEMBIC)
  find_package_wrapper(Alembic)
endif()
if(WITH_USD)
  find_package_wrapper(USD)
endif()
if(WITH_MATERIALX)
  find_package_wrapper(MaterialX)
endif()
find_package_wrapper(OpenSubdiv)
find_package_wrapper(Potrace)
set(meshoptimizer_ROOT ${LIBDIR}/meshoptimizer)
find_package_wrapper(meshoptimizer)

if(WITH_VULKAN_BACKEND)
  set(SHADERC_ROOT_DIR ${LIBDIR}/shaderc)
  find_package_wrapper(ShaderC REQUIRED)
endif()

if(WITH_EMBREE)
  find_package(Embree 4.0.0 REQUIRED)
endif()

if(WITH_GMP)
  find_package_wrapper(GMP)
  set_and_warn_library_found("GMP" GMP_FOUND WITH_GMP)
endif()

if(WITH_DRACO)
  # Draco ships a CMake config package; the glTF add-on's bridge links the
  # draco::draco target from it.
  find_package_wrapper(draco)
  if(TARGET draco::draco)
    set(DRACO_FOUND TRUE)
  endif()
  set_and_warn_library_found("Draco" DRACO_FOUND WITH_DRACO)
endif()

if(WITH_KTX)
  set(Ktx_ROOT ${LIBDIR}/ktx)
  find_package(Ktx CONFIG REQUIRED)
  if(NOT TARGET KTX::ktx)
    message(FATAL_ERROR "Android KTX package did not provide KTX::ktx")
  endif()
  set(KTX_FOUND TRUE)
endif()

if(WITH_OPENIMAGEDENOISE)
  # Blender's FindOpenImageDenoise looks for a single shared library, but the
  # Android build is static and split across core/device/common/weights
  # archives whose link order matters. OIDN ships a CMake package that already
  # encodes that graph (and pulls in TBB), so use it and hand the result to the
  # variables the rest of the build reads.
  find_package(OpenImageDenoise CONFIG REQUIRED)
  set(OPENIMAGEDENOISE_INCLUDE_DIRS ${LIBDIR}/openimagedenoise/include)
  set(OPENIMAGEDENOISE_LIBRARIES OpenImageDenoise)
  set(OPENIMAGEDENOISE_FOUND ON)
endif()

if(WITH_LLVM)
  find_package_wrapper(LLVM)
endif()

if(WITH_CODEC_FFMPEG)
  find_package(FFmpeg)
endif()

if(WITH_RUBBERBAND)
  set(RUBBERBAND_ROOT_DIR ${LIBDIR}/rubberband)
  find_package(Rubberband REQUIRED)
endif()

if(WITH_MANIFOLD)
  find_package(manifold)
  if(TARGET manifold::manifold)
    set(MANIFOLD_FOUND TRUE)
  endif()
  set_and_warn_library_found("MANIFOLD" MANIFOLD_FOUND WITH_MANIFOLD)
  mark_as_advanced(manifold_DIR)
endif()

if(WITH_LIBMV)
  find_package_wrapper(Ceres REQUIRED)
  mark_as_advanced(Ceres_DIR)
  # Dep of Ceres.
  mark_as_advanced(absl_DIR)
endif()

if(WITH_HARU)
  find_package_wrapper(Haru)
  set_and_warn_library_found("Haru" HARU_FOUND WITH_HARU)
endif()

if(WITH_FFTW3)
  find_package_wrapper(Fftw3)
  set_and_warn_library_found("fftw3" FFTW3_FOUND WITH_FFTW3)
endif()

if(WITH_CYCLES AND WITH_CYCLES_PATH_GUIDING)
  find_package_wrapper(openpgl)
  mark_as_advanced(openpgl_DIR)
  if(openpgl_FOUND)
    get_target_property(OPENPGL_LIBRARIES openpgl::openpgl LOCATION)
    get_target_property(OPENPGL_INCLUDE_DIR openpgl::openpgl INTERFACE_INCLUDE_DIRECTORIES)
  else()
    set(WITH_CYCLES_PATH_GUIDING OFF)
    message(STATUS "OpenPGL not found, disabling WITH_CYCLES_PATH_GUIDING")
  endif()
endif()
