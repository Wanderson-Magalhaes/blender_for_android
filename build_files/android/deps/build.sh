#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Cross-compile Blender's third-party dependencies for Android with the NDK.
# Each dependency installs into a harvest prefix ($LIBDIR/<name>), mirroring
# the layout of the prebuilt lib/<platform> submodules.
#
# Usage:
#   build_files/android/deps/build.sh <dep> [<dep> ...]
#   build_files/android/deps/build.sh all
#
# Versions are read from build_files/build_environment/cmake/versions.cmake.

set -euo pipefail

# Replace an ancient config.sub/config.guess pair so a cross triple is accepted.
# Sources, in order: the distribution's own copy, then any dependency already
# unpacked that carries a newer one.
refresh_config_sub() {
  local dest="$1" found=0 d
  for d in /usr/share/misc /usr/share/automake-1.16 /usr/share/libtool/build-aux \
           "$WORK_DIR/opus" "$WORK_DIR/lame"; do
    if [ -f "$d/config.sub" ] && [ -f "$d/config.guess" ]; then
      cp "$d/config.sub" "$d/config.guess" "$dest/"
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "[deps] WARNING: no recent config.sub found; a cross build may be rejected" >&2
  fi
}

# Host interpreter matching the target Python version. Needed to drive the numpy
# cross-build and to give USD Python support. Homebrew has it on macOS; on Linux
# a distribution package is usually too old, so a local build is used instead.
host_python() {
  local p
  for p in /opt/homebrew/bin/python3.13 \
           "${WORK_DIR:-}/python-host-install/bin/python3.13" \
           "$HOME/python313/bin/python3.13" \
           /usr/local/bin/python3.13 "$(command -v python3.13 2>/dev/null)"; do
    if [ -n "$p" ] && [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  echo "[deps] ERROR: no host python3.13 found; see Prerequisites in BUILDING.md" >&2
  return 1
}

# Use the native CPU-count command on each supported host.  The original
# Android scripts used the macOS sysctl spelling unconditionally, which makes
# every make-based dependency fail immediately on Linux/WSL.
build_jobs() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  else
    sysctl -n hw.ncpu
  fi
}

# BSD sed requires an argument to -i and GNU sed rejects a separate one, so
# neither spelling is portable. "-i.bak" is understood by both; the backup is
# removed straight away.
sed_i() {
  local file="${!#}"
  sed -i.bak "$@"
  rm -f "$file.bak"
}


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/build_files/android/env.sh"

# All Android build artifacts live under this sibling dir, not scattered in the
# repo's parent. Override with BUILD_BASE=... if you keep them elsewhere.
# Resolved, not "$REPO_ROOT/..": the unresolved form reaches compiler flags and
# CMake caches, where the same directory then appears under two spellings and is
# treated as two. The same slip made the APK scripts wipe their build directory
# on every run.
BUILD_BASE="${BUILD_BASE:-$(cd "$REPO_ROOT/.." && pwd)/blender_build_android}"
: "${LIBDIR:=$BUILD_BASE/lib/android_$( [ "$ANDROID_ABI" = arm64-v8a ] && echo arm64 || echo "$ANDROID_ABI")}"
DL_DIR="$BUILD_BASE/android_deps_build/downloads"
WORK_DIR="$BUILD_BASE/android_deps_build/work"
# Compilers and generators that must run on the build machine, kept apart from
# $LIBDIR so a host binary never ends up on the target's CMAKE_PREFIX_PATH.
HOST_TOOLS_DIR="$BUILD_BASE/android_deps_build/host"
VERSIONS="$REPO_ROOT/build_files/build_environment/cmake/versions.cmake"
mkdir -p "$LIBDIR" "$DL_DIR" "$WORK_DIR" "$HOST_TOOLS_DIR"

echo "[deps] LIBDIR=$LIBDIR"

# Read a `set(NAME value)` entry from versions.cmake.
dep_version() {
  sed -nE "s/^set\($1 ([^ )]+)\).*/\1/p" "$VERSIONS" | head -1
}

# Download $2 to $DL_DIR/$1 if missing.
fetch() {
  local file="$1" url="$2"
  if [ ! -f "$DL_DIR/$file" ]; then
    echo "[deps] fetching $file"
    curl -sL --max-time 300 -o "$DL_DIR/$file" "$url"
  fi
}

# Extract a tarball into $WORK_DIR and echo the resulting source dir.
extract() {
  local file="$1" name="$2"
  local dir="$WORK_DIR/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xf "$DL_DIR/$file" -C "$dir" --strip-components=1
  echo "$dir"
}

# Semicolon-separated list of all installed dep prefixes, used as find roots so
# find_*() locate our libs (rooted, mode ONLY) without picking up host libs.
find_roots() {
  local roots="" d
  for d in "$LIBDIR"/*/; do
    [ -d "$d" ] && roots="$roots${roots:+;}${d%/}"
  done
  echo "$roots"
}

# Some projects hard-link -lpthread/-lrt, which Android folds into libc.
# Create empty stub archives so those -l flags resolve. Echoes the dir.
stub_libs() {
  local dir="$LIBDIR/.stublibs"
  if [ ! -f "$dir/libpthread.a" ]; then
    mkdir -p "$dir"
    echo "" > "$WORK_DIR/empty.c"
    "$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang" -c "$WORK_DIR/empty.c" \
      -o "$WORK_DIR/empty.o"
    "$ANDROID_LLVM_BIN/llvm-ar" rcs "$dir/libpthread.a" "$WORK_DIR/empty.o"
    "$ANDROID_LLVM_BIN/llvm-ar" rcs "$dir/librt.a" "$WORK_DIR/empty.o"
  fi
  echo "$dir"
}

# Configure/build/install a CMake-based dependency for Android.
# $1 src dir, $2 install name, rest: extra cmake args.
cmake_install() {
  local src="$1" name="$2"; shift 2
  local build="$src/build-android"
  cmake -S "$src" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_TOOLCHAIN_FILE" \
    -DANDROID_ABI="$ANDROID_ABI" \
    -DANDROID_PLATFORM="android-$ANDROID_API" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$LIBDIR/$name" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_TESTING=OFF \
    -DCMAKE_FIND_ROOT_PATH="$(find_roots)" \
    "$@"
  cmake --build "$build"
  cmake --install "$build"
  echo "[deps] installed $name -> $LIBDIR/$name"
}

build_zlib() {
  local v; v="$(dep_version ZLIB_VERSION)"
  fetch "zlib-$v.tar.gz" "https://github.com/madler/zlib/releases/download/v$v/zlib-$v.tar.gz"
  local src; src="$(extract "zlib-$v.tar.gz" zlib)"
  cmake_install "$src" zlib -DZLIB_BUILD_EXAMPLES=OFF
}

build_zstd() {
  local v; v="$(dep_version ZSTD_VERSION)"
  fetch "zstd-$v.tar.gz" "https://github.com/facebook/zstd/releases/download/v$v/zstd-$v.tar.gz"
  local src; src="$(extract "zstd-$v.tar.gz" zstd)"
  # zstd keeps its CMake project in build/cmake.
  cmake_install "$src/build/cmake" zstd \
    -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_SHARED=ON \
    -DZSTD_BUILD_STATIC=ON
}

build_deflate() {
  local v; v="$(dep_version DEFLATE_VERSION)"
  fetch "libdeflate-$v.tar.gz" "https://github.com/ebiggers/libdeflate/archive/refs/tags/v$v.tar.gz"
  local src; src="$(extract "libdeflate-$v.tar.gz" deflate)"
  cmake_install "$src" deflate \
    -DLIBDEFLATE_BUILD_SHARED_LIB=ON \
    -DLIBDEFLATE_BUILD_STATIC_LIB=ON \
    -DLIBDEFLATE_BUILD_GZIP=OFF
}

build_imath() {
  local v; v="$(dep_version IMATH_VERSION)"
  fetch "imath-$v.tar.gz" "https://github.com/AcademySoftwareFoundation/Imath/archive/v$v.tar.gz"
  local src; src="$(extract "imath-$v.tar.gz" imath)"
  cmake_install "$src" imath -DBUILD_SHARED_LIBS=ON -DPYTHON=OFF -DIMATH_INSTALL_PKG_CONFIG=ON
}

build_fmt() {
  local v; v="$(dep_version FMT_VERSION)"
  fetch "fmt-$v.tar.gz" "https://github.com/fmtlib/fmt/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "fmt-$v.tar.gz" fmt)"
  cmake_install "$src" fmt -DFMT_TEST=OFF -DFMT_DOC=OFF -DBUILD_SHARED_LIBS=OFF
}

build_tbb() {
  local v; v="$(dep_version TBB_VERSION)"  # e.g. v2022.3.0
  fetch "onetbb-$v.tar.gz" "https://github.com/uxlfoundation/oneTBB/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "onetbb-$v.tar.gz" tbb)"
  # NDK sets --no-undefined-version; oneTBB def files list symbols not built,
  # so allow undefined version-script symbols.
  cmake_install "$src" tbb \
    -DTBB_TEST=OFF \
    -DTBB_STRICT=OFF \
    -DTBB_INSTALL=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--undefined-version"
}

build_png() {
  local v; v="$(dep_version PNG_VERSION)"
  fetch "libpng-$v.tar.xz" "https://downloads.sourceforge.net/libpng/libpng-$v.tar.xz"
  local src; src="$(extract "libpng-$v.tar.xz" png)"
  cmake_install "$src" png \
    -DCMAKE_PREFIX_PATH="$LIBDIR/zlib" \
    -DPNG_TESTS=OFF \
    -DPNG_SHARED=ON \
    -DPNG_STATIC=ON \
    -DPNG_TOOLS=OFF
}

build_pugixml() {
  local v; v="$(dep_version PUGIXML_VERSION)"
  fetch "pugixml-$v.tar.gz" "https://github.com/zeux/pugixml/archive/v$v.tar.gz"
  local src; src="$(extract "pugixml-$v.tar.gz" pugixml)"
  # pugixml 1.10 predates CMake 4's minimum-policy floor.
  cmake_install "$src" pugixml -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
}

build_brotli() {
  local v; v="$(dep_version BROTLI_VERSION)"
  fetch "brotli-$v.tar.gz" "https://github.com/google/brotli/archive/refs/tags/v$v.tar.gz"
  local src; src="$(extract "brotli-$v.tar.gz" brotli)"
  cmake_install "$src" brotli -DBROTLI_DISABLE_TESTS=ON
}

build_ktx() {
  local v; v="$(dep_version KTX_VERSION)"
  fetch "ktx-$v.tar.gz" "https://github.com/KhronosGroup/KTX-Software/archive/refs/tags/v$v.tar.gz"
  printf '%s  %s\n' "$(dep_version KTX_HASH)" "$DL_DIR/ktx-$v.tar.gz" | sha256sum -c -
  local src; src="$(extract "ktx-$v.tar.gz" ktx)"
  patch -p1 -d "$src" < "$REPO_ROOT/build_files/build_environment/patches/ktx_zstd_dep_fix.diff"
  patch -p1 -d "$src" < "$REPO_ROOT/build_files/build_environment/patches/ktx_asan.diff"
  # Upstream KTX bounds the search for the needle's terminator by the haystack's
  # length, which overreads short needles. Android aborts on it; see the patch.
  patch -p1 -d "$src" < "$REPO_ROOT/build_files/build_environment/patches/ktx_strnstr_needle_bounds.diff"
  cmake_install "$src" ktx \
    -DKTX_FEATURE_TOOLS=OFF -DKTX_FEATURE_TESTS=OFF \
    -DKTX_FEATURE_ETC_UNPACK=OFF -DKTX_FEATURE_STATIC_LIBRARY=OFF \
    -DASTCENC_ISA_NEON=ON -DASTCENC_ISA_AVX2=OFF \
    -DASTCENC_ISA_SSE41=OFF -DASTCENC_ISA_SSE2=OFF \
    -Dzstd_ROOT="$LIBDIR/zstd"
}

build_freetype() {
  local v; v="$(dep_version FREETYPE_VERSION)"
  fetch "freetype-$v.tar.gz" "https://downloads.sourceforge.net/freetype/freetype-$v.tar.gz"
  local src; src="$(extract "freetype-$v.tar.gz" freetype)"
  cmake_install "$src" freetype \
    -DCMAKE_PREFIX_PATH="$LIBDIR/zlib;$LIBDIR/png;$LIBDIR/brotli" \
    -DFT_REQUIRE_ZLIB=ON \
    -DFT_REQUIRE_PNG=ON \
    -DFT_REQUIRE_BROTLI=ON \
    -DFT_DISABLE_HARFBUZZ=ON \
    -DFT_DISABLE_BZIP2=ON \
    -DBUILD_SHARED_LIBS=ON
}

build_harfbuzz() {
  local v; v="$(dep_version HARFBUZZ_VERSION)"
  fetch "harfbuzz-$v.tar.gz" "https://github.com/harfbuzz/harfbuzz/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "harfbuzz-$v.tar.gz" harfbuzz)"
  cmake_install "$src" harfbuzz \
    -DCMAKE_PREFIX_PATH="$LIBDIR/freetype" \
    -DHB_HAVE_FREETYPE=ON \
    -DHB_BUILD_SUBSET=OFF \
    -DBUILD_SHARED_LIBS=ON
}

build_tiff() {
  local v; v="$(dep_version TIFF_VERSION)"
  fetch "tiff-$v.tar.gz" "https://download.osgeo.org/libtiff/tiff-$v.tar.gz"
  local src; src="$(extract "tiff-$v.tar.gz" tiff)"
  cmake_install "$src" tiff \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-docs=OFF \
    -Dwebp=OFF -Dlerc=OFF -Djbig=OFF
}

build_webp() {
  local v; v="$(dep_version WEBP_VERSION)"
  fetch "libwebp-$v.tar.gz" "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$v.tar.gz"
  local src; src="$(extract "libwebp-$v.tar.gz" webp)"
  cmake_install "$src" webp \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
}

build_jpeg() {
  local v; v="$(dep_version JPEG_VERSION)"
  fetch "libjpeg-turbo-$v.tar.gz" "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/$v.tar.gz"
  local src; src="$(extract "libjpeg-turbo-$v.tar.gz" jpeg)"
  cmake_install "$src" jpeg \
    -DENABLE_SHARED=ON \
    -DENABLE_STATIC=ON \
    -DWITH_JPEG8=ON \
    -DWITH_TURBOJPEG=OFF
}

build_openjpeg() {
  local v; v="$(dep_version OPENJPEG_VERSION)"
  fetch "openjpeg-$v.tar.gz" "https://github.com/uclouvain/openjpeg/archive/v$v.tar.gz"
  local src; src="$(extract "openjpeg-$v.tar.gz" openjpeg)"
  cmake_install "$src" openjpeg -DBUILD_CODEC=OFF
}

build_expat() {
  local v; v="$(dep_version EXPAT_VERSION)"  # underscore form, e.g. 2_7_5
  fetch "expat-$v.tar.gz" "https://github.com/libexpat/libexpat/archive/R_$v.tar.gz"
  local src; src="$(extract "expat-$v.tar.gz" expat)"
  cmake_install "$src/expat" expat -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF
}

build_yamlcpp() {
  local v; v="$(dep_version YAMLCPP_VERSION)"
  fetch "yaml-cpp-$v.tar.gz" "https://github.com/jbeder/yaml-cpp/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "yaml-cpp-$v.tar.gz" yamlcpp)"
  cmake_install "$src" yamlcpp -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF
}

build_blosc() {
  local v; v="$(dep_version BLOSC_VERSION)"
  fetch "c-blosc-$v.tar.gz" "https://github.com/Blosc/c-blosc/archive/v$v.tar.gz"
  local src; src="$(extract "c-blosc-$v.tar.gz" blosc)"
  cmake_install "$src" blosc \
    -DBUILD_TESTS=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_FUZZERS=OFF \
    -DPREFER_EXTERNAL_ZLIB=ON -DPREFER_EXTERNAL_ZSTD=ON
}

build_pystring() {
  local v; v="$(dep_version PYSTRING_VERSION)"  # v1.1.3
  fetch "pystring-$v.tar.gz" "https://github.com/imageworks/pystring/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "pystring-$v.tar.gz" pystring)"
  # pystring ships no build system; reuse Blender's supplied CMakeLists.
  cp "$REPO_ROOT/build_files/build_environment/patches/cmakelists_pystring.txt" \
    "$src/CMakeLists.txt"
  cmake_install "$src" pystring
}

build_minizipng() {
  local v; v="$(dep_version MINIZIPNG_VERSION)"
  fetch "minizip-ng-$v.tar.gz" "https://github.com/zlib-ng/minizip-ng/archive/$v.tar.gz"
  local src; src="$(extract "minizip-ng-$v.tar.gz" minizipng)"
  cmake_install "$src" minizipng \
    -DMZ_FETCH_LIBS=OFF -DMZ_LIBCOMP=OFF -DMZ_PKCRYPT=OFF -DMZ_WZAES=OFF \
    -DMZ_OPENSSL=OFF -DMZ_SIGNING=OFF -DMZ_LZMA=OFF -DMZ_ZSTD=OFF \
    -DMZ_BZIP2=OFF -DMZ_ICONV=OFF
}

build_opencolorio() {
  local v; v="$(dep_version OPENCOLORIO_VERSION)"
  fetch "opencolorio-$v.tar.gz" "https://github.com/AcademySoftwareFoundation/OpenColorIO/archive/v$v.tar.gz"
  local src; src="$(extract "opencolorio-$v.tar.gz" opencolorio)"
  # Python bindings off until Python is cross-compiled; use our harvested deps.
  # minizip-ng installs itself as libminizip.a, but OCIO's find module searches
  # for the name minizip-ng and gives up. Point it at the file directly, which
  # the module documents and which does not depend on the CMake version.
  cmake_install "$src" opencolorio \
    -DOCIO_INSTALL_EXT_PACKAGES=NONE \
    -DOCIO_BUILD_APPS=OFF -DOCIO_BUILD_PYTHON=OFF -DOCIO_BUILD_NUKE=OFF \
    -DOCIO_BUILD_JAVA=OFF -DOCIO_BUILD_DOCS=OFF -DOCIO_BUILD_TESTS=OFF \
    -DOCIO_BUILD_GPU_TESTS=OFF -DOCIO_USE_SSE=OFF \
    -Dminizip-ng_ROOT="$LIBDIR/minizipng" -Dpystring_ROOT="$LIBDIR/pystring" \
    -Dminizip-ng_LIBRARY="$LIBDIR/minizipng/lib/libminizip.a" \
    -Dminizip-ng_INCLUDE_DIR="$LIBDIR/minizipng/include/minizip"
}

build_opensubdiv() {
  local v; v="$(dep_version OPENSUBDIV_VERSION)"  # v3_7_0
  fetch "opensubdiv-$v.tar.gz" "https://github.com/PixarAnimationStudios/OpenSubdiv/archive/$v.tar.gz"
  local src; src="$(extract "opensubdiv-$v.tar.gz" opensubdiv)"
  # NDK ships GLES, so OpenSubdiv enables OSD_GPU with no GPU sources; gate it.
  sed_i 's/if(OPENGLES_FOUND)/if(OPENGLES_FOUND AND NOT NO_OPENGL)/' \
    "$src/CMakeLists.txt"
  # Its ANDROID block installs Android.mk to LIBRARY_OUTPUT_PATH_ROOT; set it.
  # Blender's GPU subdiv needs glslPatchShaderSource (a source-string
  # generator, no GL context); enable it without a GL loader.
  cmake_install "$src" opensubdiv \
    -DTBB_ROOT="$LIBDIR/tbb" \
    -DOSD_PATCH_SHADER_SOURCE_GLSL=ON \
    -DLIBRARY_OUTPUT_PATH_ROOT="$LIBDIR/opensubdiv" \
    -DNO_TUTORIALS=ON -DNO_EXAMPLES=ON -DNO_REGRESSION=ON -DNO_DOC=ON \
    -DNO_OMP=ON -DNO_CUDA=ON -DNO_OPENCL=ON -DNO_METAL=ON -DNO_DX=ON \
    -DNO_OPENGL=ON -DNO_TBB=OFF -DNO_PTEX=ON -DNO_GLTESTS=ON -DNO_GLEW=ON -DNO_GLFW=ON
}

build_robinmap() {
  local v; v="$(dep_version ROBINMAP_VERSION)"
  fetch "robinmap-$v.tar.gz" "https://github.com/Tessil/robin-map/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "robinmap-$v.tar.gz" robinmap)"
  cmake_install "$src" robinmap
}

build_openimageio() {
  local v; v="$(dep_version OPENIMAGEIO_VERSION)"  # v3.1.13.1
  fetch "oiio-$v.tar.gz" "https://github.com/AcademySoftwareFoundation/OpenImageIO/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "oiio-$v.tar.gz" openimageio)"
  patch -p1 -d "$src" < "$REPO_ROOT/build_files/build_environment/patches/openimageio_psd.diff"
  cmake_install "$src" openimageio \
    -DBUILD_SHARED_LIBS=ON \
    -DOIIO_BUILD_TESTS=OFF -DOIIO_BUILD_TOOLS=OFF \
    -DUSE_PYTHON=OFF -DUSE_LIBRAW=OFF -DUSE_QT=OFF -DUSE_OPENGL=OFF \
    -DUSE_FFMPEG=OFF -DUSE_LIBHEIF=OFF -DUSE_OPENJPH=OFF -DUSE_OPENVDB=OFF \
    -DUSE_DCMTK=OFF -DUSE_NUKE=OFF -DUSE_TBB=ON \
    -DFMT_INCLUDE_DIR="$LIBDIR/fmt/include" -Dfmt_ROOT="$LIBDIR/fmt" \
    -DRobinmap_ROOT="$LIBDIR/robinmap"
}

# Configure/build/install an autotools dependency for Android via the NDK.
# $1 src dir, $2 install name, rest: extra ./configure args.
autotools_install() {
  local src="$1" name="$2"; shift 2
  local host=aarch64-linux-android
  export CC="$ANDROID_LLVM_BIN/${host}${ANDROID_API}-clang"
  export CXX="$ANDROID_LLVM_BIN/${host}${ANDROID_API}-clang++"
  export AR="$ANDROID_LLVM_BIN/llvm-ar" RANLIB="$ANDROID_LLVM_BIN/llvm-ranlib"
  export STRIP="$ANDROID_LLVM_BIN/llvm-strip"
  export CFLAGS="-fPIC -O2 -I$LIBDIR/zlib/include"
  export LDFLAGS="-L$LIBDIR/zlib/lib ${EXTRA_LDFLAGS:-}"
  ( cd "$src" && ./configure --host="$host" --prefix="$LIBDIR/$name" "$@" &&
    make -j"$(build_jobs)" && make install )
  unset CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
  echo "[deps] installed $name -> $LIBDIR/$name"
}

# GMP, for the exact boolean solver. Without it the Boolean modifier and the
# boolean edit-mode tools only offer the fast float solver, which is the one
# that produces holes and stray faces on awkward intersections.
build_gmp() {
  local v; v="$(dep_version GMP_VERSION)"
  # gmplib.org truncated the transfer more than once; the GNU mirror carries
  # the identical tarball and has been reliable.
  fetch "gmp-$v.tar.xz" "https://ftp.gnu.org/gnu/gmp/gmp-$v.tar.xz"
  local src; src="$(extract "gmp-$v.tar.xz" gmp)"
  # Blender links the C++ interface as well, so --enable-cxx is not optional.
  autotools_install "$src" gmp --enable-cxx --disable-static --enable-shared
}

build_potrace() {
  local v; v="$(dep_version POTRACE_VERSION)"
  fetch "potrace-$v.tar.gz" "https://potrace.sourceforge.net/download/$v/potrace-$v.tar.gz"
  local src; src="$(extract "potrace-$v.tar.gz" potrace)"
  autotools_install "$src" potrace --with-libpotrace --disable-static --enable-shared
}

build_sqlite() {
  local v; v="$(dep_version SQLITE_VERSION)"
  local lv; lv="$(sed -nE 's/^set\(SQLLITE_LONG_VERSION ([0-9]+)\).*/\1/p' "$VERSIONS")"
  fetch "sqlite-$v.tar.gz" "https://www.sqlite.org/2026/sqlite-autoconf-$lv.tar.gz"
  local src; src="$(extract "sqlite-$v.tar.gz" sqlite)"
  autotools_install "$src" sqlite \
    --enable-rtree --enable-fts4 --enable-fts5 --enable-threadsafe
}

build_libffi() {
  local v; v="$(dep_version FFI_VERSION)"
  fetch "libffi-$v.tar.gz" "https://github.com/libffi/libffi/releases/download/v$v/libffi-$v.tar.gz"
  local src; src="$(extract "libffi-$v.tar.gz" libffi)"
  autotools_install "$src" libffi --disable-static --enable-shared --disable-docs
}

build_openssl() {
  local v; v="$(dep_version SSL_VERSION)"
  fetch "openssl-$v.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-$v/openssl-$v.tar.gz"
  local src; src="$(extract "openssl-$v.tar.gz" openssl)"
  # OpenSSL has native Android targets; it reads ANDROID_NDK_ROOT + PATH.
  export ANDROID_NDK_ROOT PATH="$ANDROID_LLVM_BIN:$PATH"
  ( cd "$src" &&
    ./Configure android-arm64 -D__ANDROID_API__="$ANDROID_API" \
      no-tests no-apps shared --prefix="$LIBDIR/openssl" --libdir=lib &&
    make -j"$(build_jobs)" && make install_sw )
  echo "[deps] installed openssl -> $LIBDIR/openssl"
}

build_python() {
  local v; v="$(dep_version PYTHON_VERSION)"  # 3.13.13
  local mm="${v%.*}"                           # 3.13
  fetch "Python-$v.tar.xz" "https://www.python.org/ftp/python/$v/Python-$v.tar.xz"

  # Stage 1: a host interpreter of the exact version, for cross build tooling.
  local host_src; host_src="$(extract "Python-$v.tar.xz" python-host)"
  local host_prefix="$WORK_DIR/python-host-install"
  if [ ! -x "$host_prefix/bin/python$mm" ]; then
    # Keep ensurepip here (the target build below stays without it). numpy's
    # cross-build makes a venv from this interpreter and pip-installs cython and
    # meson-python into it; on macOS that came from Homebrew's python3.13, but on
    # Linux this is the only 3.13 available and a --without-ensurepip build makes
    # `python -m venv` fail outright.
    ( cd "$host_src" && ./configure --prefix="$host_prefix" --with-ensurepip=install \
        --disable-test-modules >/dev/null &&
      make -j"$(build_jobs)" >/dev/null && make install >/dev/null )
  fi

  # Stage 2: cross-compile for Android against our harvested deps.
  local src; src="$(extract "Python-$v.tar.xz" python)"
  local site="$WORK_DIR/python-config.site"
  cat >"$site" <<'EOF'
ac_cv_file__dev_ptmx=no
ac_cv_file__dev_ptc=no
ac_cv_little_endian_double=yes
EOF
  export CC="$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang"
  export CXX="$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang++"
  export AR="$ANDROID_LLVM_BIN/llvm-ar" RANLIB="$ANDROID_LLVM_BIN/llvm-ranlib"
  export READELF="$ANDROID_LLVM_BIN/llvm-readelf"
  export CONFIG_SITE="$site"
  export CPPFLAGS="-I$LIBDIR/zlib/include -I$LIBDIR/sqlite/include -I$LIBDIR/libffi/include -I$LIBDIR/lzma/include -I$LIBDIR/bzip2/include"
  export LDFLAGS="-L$LIBDIR/zlib/lib -L$LIBDIR/sqlite/lib -L$LIBDIR/libffi/lib -L$LIBDIR/lzma/lib -L$LIBDIR/bzip2/lib"
  export PKG_CONFIG_LIBDIR="$LIBDIR/libffi/lib/pkgconfig:$LIBDIR/openssl/lib/pkgconfig:$LIBDIR/zlib/lib/pkgconfig:$LIBDIR/sqlite/lib/pkgconfig"
  ( cd "$src" &&
    ./configure --host=aarch64-linux-android --build="$(./config.guess)" \
      --with-build-python="$host_prefix/bin/python$mm" \
      --with-openssl="$LIBDIR/openssl" \
      --enable-shared --without-ensurepip --disable-test-modules \
      --prefix="$LIBDIR/python" &&
    make -j"$(build_jobs)" && make install )
  unset CC CXX AR RANLIB READELF CONFIG_SITE CPPFLAGS LDFLAGS PKG_CONFIG_LIBDIR
  # The cross-built .pc leaves $(BLDLIBRARY) unexpanded; resolve it.
  sed_i 's/\$(BLDLIBRARY)/-lpython3.13/' "$LIBDIR/python/lib/pkgconfig/python-$mm.pc"
  echo "[deps] installed python -> $LIBDIR/python"
}

build_openvdb() {
  local v; v="$(dep_version OPENVDB_VERSION)"
  fetch "openvdb-$v.tar.gz" "https://github.com/AcademySoftwareFoundation/openvdb/archive/v$v.tar.gz"
  local src; src="$(extract "openvdb-$v.tar.gz" openvdb)"
  # DELAYED_LOADING=OFF drops the Boost dependency (not used by Blender).
  cmake_install "$src" openvdb \
    -DOPENVDB_USE_DELAYED_LOADING=OFF \
    -DOPENVDB_CORE_SHARED=ON -DOPENVDB_CORE_STATIC=OFF \
    -DOPENVDB_BUILD_BINARIES=OFF -DOPENVDB_BUILD_UNITTESTS=OFF \
    -DOPENVDB_BUILD_NANOVDB=ON -DNANOVDB_BUILD_TOOLS=OFF -DUSE_NANOVDB=ON \
    -DOPENVDB_BUILD_PYTHON_MODULE=OFF \
    -DUSE_BLOSC=ON -DBlosc_ROOT="$LIBDIR/blosc" -DTBB_ROOT="$LIBDIR/tbb"
}

build_ogg() {
  local v; v="$(dep_version OGG_VERSION)"
  fetch "libogg-$v.tar.gz" "https://downloads.xiph.org/releases/ogg/libogg-$v.tar.gz"
  local src; src="$(extract "libogg-$v.tar.gz" ogg)"
  autotools_install "$src" ogg --disable-static --enable-shared
}

build_vorbis() {
  local v; v="$(dep_version VORBIS_VERSION)"
  fetch "libvorbis-$v.tar.gz" "https://downloads.xiph.org/releases/vorbis/libvorbis-$v.tar.gz"
  local src; src="$(extract "libvorbis-$v.tar.gz" vorbis)"
  autotools_install "$src" vorbis --disable-static --enable-shared --with-ogg="$LIBDIR/ogg"
}

build_theora() {
  local v; v="$(dep_version THEORA_VERSION)"
  fetch "libtheora-$v.tar.bz2" "https://downloads.xiph.org/releases/theora/libtheora-$v.tar.bz2"
  local src; src="$(extract "libtheora-$v.tar.bz2" theora)"
  # theora 1.1.1 ships a 2009 config.sub that rejects aarch64-linux-android.
  # Taking it from opus only worked when opus happened to be built first, and
  # the failure was silent, so prefer the host's copy and say so when neither
  # source is available.
  refresh_config_sub "$src"
  autotools_install "$src" theora --disable-static --enable-shared \
    --with-ogg="$LIBDIR/ogg" --with-vorbis="$LIBDIR/vorbis" \
    --disable-examples --disable-oggtest --disable-vorbistest
}

build_opus() {
  local v; v="$(dep_version OPUS_VERSION)"
  fetch "opus-$v.tar.gz" "https://archive.mozilla.org/pub/opus/opus-$v.tar.gz"
  local src; src="$(extract "opus-$v.tar.gz" opus)"
  autotools_install "$src" opus --disable-static --enable-shared --disable-doc --disable-extra-programs
}

build_lame() {
  local v; v="$(dep_version LAME_VERSION)"
  fetch "lame-$v.tar.gz" "https://downloads.sourceforge.net/project/lame/lame/$v/lame-$v.tar.gz"
  local src; src="$(extract "lame-$v.tar.gz" lame)"
  # lame's symbol map lists lame_init_old which isn't built; allow it.
  EXTRA_LDFLAGS="-Wl,--undefined-version" \
    autotools_install "$src" lame --disable-static --enable-shared --disable-frontend
}

build_x265() {
  local v; v="$(dep_version X265_VERSION)"
  fetch "x265_$v.tar.gz" "https://bitbucket.org/multicoreware/x265_git/downloads/x265_$v.tar.gz"
  local src; src="$(extract "x265_$v.tar.gz" x265)"
  # CMake 4 dropped OLD for CMP0025/CMP0054; x265 forces them.
  sed_i -E 's/cmake_policy\(SET (CMP0025|CMP0054) OLD\)/cmake_policy(SET \1 NEW)/' \
    "$src/source/CMakeLists.txt"
  # ENABLE_ASSEMBLY off: x265's arm path passes -mcpu=armv8-a which clang
  # rejects as a CPU name. Functional without asm (slower HEVC encode).
  local stub; stub="$(stub_libs)"
  cmake_install "$src/source" x265 -DENABLE_SHARED=ON -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$stub" -DCMAKE_EXE_LINKER_FLAGS="-L$stub"
}

build_aom() {
  local v; v="$(dep_version AOM_VERSION)"
  fetch "libaom-$v.tar.gz" "https://storage.googleapis.com/aom-releases/libaom-$v.tar.gz"
  local src; src="$(extract "libaom-$v.tar.gz" aom)"
  cmake_install "$src" aom \
    -DBUILD_SHARED_LIBS=ON -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF \
    -DENABLE_TOOLS=OFF -DENABLE_DOCS=OFF
}

build_vpx() {
  local v; v="$(dep_version VPX_VERSION)"
  fetch "libvpx-v$v.tar.gz" "https://github.com/webmproject/libvpx/archive/v$v/libvpx-v$v.tar.gz"
  local src; src="$(extract "libvpx-v$v.tar.gz" vpx)"
  export CC="$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang"
  export CXX="$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang++"
  export LD="$CC" AR="$ANDROID_LLVM_BIN/llvm-ar" \
    STRIP="$ANDROID_LLVM_BIN/llvm-strip" NM="$ANDROID_LLVM_BIN/llvm-nm"
  ( cd "$src" && ./configure --target=arm64-android-gcc \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      --enable-pic --enable-vp8 --enable-vp9 --enable-static --disable-shared \
      --prefix="$LIBDIR/vpx" &&
    make -j"$(build_jobs)" && make install )
  unset CC CXX LD AR STRIP NM
  echo "[deps] installed vpx -> $LIBDIR/vpx"
}

build_x264() {
  local v; v="$(dep_version X264_VERSION)"
  fetch "x264-$v.tar.gz" "https://code.videolan.org/videolan/x264/-/archive/$v/x264-$v.tar.gz"
  local src; src="$(extract "x264-$v.tar.gz" x264)"
  export CC="$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang"
  export AR="$ANDROID_LLVM_BIN/llvm-ar" RANLIB="$ANDROID_LLVM_BIN/llvm-ranlib" \
    STRIP="$ANDROID_LLVM_BIN/llvm-strip"
  ( cd "$src" && ./configure --host=aarch64-linux-android \
      --cross-prefix="$ANDROID_LLVM_BIN/llvm-" --sysroot="$ANDROID_SYSROOT" \
      --enable-pic --enable-shared --disable-cli --disable-static \
      --prefix="$LIBDIR/x264" &&
    make -j"$(build_jobs)" && make install )
  unset CC AR RANLIB STRIP
  echo "[deps] installed x264 -> $LIBDIR/x264"
}

build_ffmpeg() {
  local v; v="$(dep_version FFMPEG_VERSION)"
  fetch "ffmpeg-$v.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$v.tar.xz"
  local src; src="$(extract "ffmpeg-$v.tar.xz" ffmpeg)"
  local pc="" xcf="" xlf=""
  for d in opus vorbis ogg theora x264 x265 vpx aom openjpeg lame; do
    pc="$pc${pc:+:}$LIBDIR/$d/lib/pkgconfig"
    xcf="$xcf -I$LIBDIR/$d/include"
    xlf="$xlf -L$LIBDIR/$d/lib"
  done
  export PKG_CONFIG_LIBDIR="$pc"
  ( cd "$src" && ./configure \
      --enable-cross-compile --target-os=android --arch=aarch64 \
      --cc="$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang" \
      --cxx="$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang++" \
      --ar="$ANDROID_LLVM_BIN/llvm-ar" --ranlib="$ANDROID_LLVM_BIN/llvm-ranlib" \
      --strip="$ANDROID_LLVM_BIN/llvm-strip" --nm="$ANDROID_LLVM_BIN/llvm-nm" \
      --sysroot="$ANDROID_SYSROOT" \
      --enable-shared --disable-static --enable-pic --disable-programs --disable-doc \
      --enable-gpl --enable-version3 \
      --enable-libvpx --enable-libx264 --enable-libx265 --enable-libvorbis \
      --enable-libtheora --enable-libopus --enable-libmp3lame \
      --enable-libopenjpeg --enable-libaom \
      --extra-cflags="$xcf" \
      --extra-ldflags="$xlf" --extra-libs="-lc++" \
      --prefix="$LIBDIR/ffmpeg" &&
    make -j"$(build_jobs)" && make install )
  unset PKG_CONFIG_LIBDIR
  echo "[deps] installed ffmpeg -> $LIBDIR/ffmpeg"
}

build_llvm() {
  local v; v="$(dep_version LLVM_VERSION)"
  fetch "llvm-project-$v.src.tar.xz" \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-$v/llvm-project-$v.src.tar.xz"
  local src; src="$(extract "llvm-project-$v.src.tar.xz" llvm)"

  # Stage 1: host tablegen tools (needed to cross-build LLVM/clang).
  local host_build="$src/build-host"
  if [ ! -x "$host_build/bin/llvm-tblgen" ]; then
    cmake -S "$src/llvm" -B "$host_build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS=clang \
      -DLLVM_TARGETS_TO_BUILD=AArch64
    cmake --build "$host_build" --target llvm-tblgen clang-tblgen
  fi

  # Stage 2: cross-compile LLVM + clang for Android.
  cmake_install "$src/llvm" llvm \
    -DLLVM_TABLEGEN="$host_build/bin/llvm-tblgen" \
    -DCLANG_TABLEGEN="$host_build/bin/clang-tblgen" \
    -DLLVM_ENABLE_PROJECTS=clang \
    -DLLVM_TARGETS_TO_BUILD="AArch64;ARM;NVPTX" \
    -DLLVM_HOST_TRIPLE=aarch64-linux-android \
    -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-android \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_UNWIND_TABLES=OFF \
    -DLLVM_ENABLE_PIC=ON -DLLVM_BUILD_TOOLS=OFF -DLLVM_ENABLE_RTTI=ON
}

build_usd() {
  local v; v="$(dep_version USD_VERSION)"
  fetch "openusd-$v.tar.gz" "https://github.com/PixarAnimationStudios/OpenUSD/archive/v$v.tar.gz"
  local src; src="$(extract "openusd-$v.tar.gz" usd)"
  # Blender's patch removes the Boost dependency.
  patch -p1 -d "$src" < "$REPO_ROOT/build_files/build_environment/patches/usd_noboost.diff"
  # The monolithic library carries the Python bindings, so it has to link
  # libpython. Setting Python3_LIBRARY alone is not enough: whether FindPython3
  # puts it on the link line differs between CMake 3.x and 4.x, and with 3.x the
  # build ends in a wall of undefined CPython symbols. Naming it for the linker
  # works either way.
  # Android uses libc++ (no __gnu_cxx); don't enable GNU STL extensions there.
  sed_i 's/#if defined(ARCH_OS_LINUX) \&\& defined(ARCH_COMPILER_GCC)/#if defined(ARCH_OS_LINUX) \&\& defined(ARCH_COMPILER_GCC) \&\& !defined(__ANDROID__)/' \
    "$src/pxr/base/arch/defines.h"
  cmake_install "$src" usd \
    -DPXR_BUILD_MONOLITHIC=ON \
    -DPXR_ENABLE_PYTHON_SUPPORT=ON -DPXR_USE_PYTHON_3=ON \
    -DPython3_EXECUTABLE="$(host_python)" \
    -DPython3_INCLUDE_DIR="$LIBDIR/python/include/python3.13" \
    -DPython3_LIBRARY="$LIBDIR/python/lib/libpython3.13.so" \
    -DPXR_BUILD_IMAGING=ON -DPXR_ENABLE_GL_SUPPORT=OFF \
    -DPXR_ENABLE_MATERIALX_SUPPORT=ON -DPXR_ENABLE_OPENVDB_SUPPORT=ON \
    -DPXR_BUILD_OPENIMAGEIO_PLUGIN=ON -DPXR_ENABLE_OSL_SUPPORT=OFF \
    -DPXR_ENABLE_HDF5_SUPPORT=OFF -DPXR_ENABLE_PTEX_SUPPORT=OFF \
    -DPXR_BUILD_TESTS=OFF -DPXR_BUILD_EXAMPLES=OFF -DPXR_BUILD_TUTORIALS=OFF \
    -DPXR_BUILD_USDVIEW=OFF -DPXR_BUILD_USD_TOOLS=OFF \
    -DTBB_ROOT="$LIBDIR/tbb" \
    -DCMAKE_CXX_FLAGS="-DNOFILE=1024 -D__environ=environ" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$LIBDIR/python/lib -lpython3.13"
}

build_eigen() {
  local v; v="$(dep_version EIGEN_VERSION)"
  # GitLab's archive endpoint is protected by an HTML challenge on some build
  # hosts. Fetch the exact Blender-pinned commit through the official Git
  # endpoint instead; this preserves the intended revision without accepting
  # an unverified replacement tarball.
  local src="$WORK_DIR/eigen"
  rm -rf "$src"
  git init -q "$src"
  git -C "$src" remote add origin https://gitlab.com/libeigen/eigen.git
  git -C "$src" fetch -q --depth=1 origin "$v"
  git -C "$src" checkout -q FETCH_HEAD
  cmake_install "$src" eigen -DEIGEN_BUILD_DOC=OFF -DBUILD_TESTING=OFF
}

build_rubberband() {
  local v; v="$(dep_version RUBBERBAND_VERSION)"
  fetch "rubberband-$v.tar.bz2" \
    "https://breakfastquay.com/files/releases/rubberband-$v.tar.bz2"
  local src; src="$(extract "rubberband-$v.tar.bz2" rubberband)"
  patch -p1 -d "$src" \
    < "$REPO_ROOT/build_files/build_environment/patches/rubberband_missing_cstdlib.diff"
  # meson build; bundled kissfft + builtin resampler avoid the fftw dep (off on
  # Android). auto_features=disabled drops cmdline/vamp/ladspa/lv2/jni.
  local cross="$WORK_DIR/rubberband-cross.ini"
  cat >"$cross" <<EOF
[binaries]
c = '$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang'
cpp = '$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang++'
ar = '$ANDROID_LLVM_BIN/llvm-ar'
strip = '$ANDROID_LLVM_BIN/llvm-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
  ( cd "$src" && meson setup build-android --cross-file "$cross" \
      --prefix="$LIBDIR/rubberband" --libdir lib --default-library=shared \
      -Dauto_features=disabled -Dfft=kissfft -Dresampler=builtin &&
    ninja -C build-android && ninja -C build-android install )
  echo "[deps] installed rubberband -> $LIBDIR/rubberband"
}

build_sse2neon() {
  local v; v="$(dep_version SSE2NEON_VERSION)"
  fetch "sse2neon-$v.tar.gz" "https://github.com/DLTcollab/sse2neon/archive/$v.tar.gz"
  local src; src="$(extract "sse2neon-$v.tar.gz" sse2neon)"
  # Header-only: just install the header.
  mkdir -p "$LIBDIR/sse2neon/include"
  cp "$src/sse2neon.h" "$LIBDIR/sse2neon/include/"
  echo "[deps] installed sse2neon -> $LIBDIR/sse2neon"
}

build_fribidi() {
  local v; v="$(dep_version FRIBIDI_VERSION)"
  fetch "fribidi-$v.tar.gz" "https://github.com/fribidi/fribidi/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "fribidi-$v.tar.gz" fribidi)"
  # fribidi uses meson; build with a cross file.
  local cross="$WORK_DIR/fribidi-cross.ini"
  cat >"$cross" <<EOF
[binaries]
c = '$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang'
ar = '$ANDROID_LLVM_BIN/llvm-ar'
strip = '$ANDROID_LLVM_BIN/llvm-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
  ( cd "$src" && meson setup build-android --cross-file "$cross" \
      --prefix="$LIBDIR/fribidi" -Ddocs=false -Dtests=false -Dbin=false --default-library=shared &&
    ninja -C build-android && ninja -C build-android install )
  echo "[deps] installed fribidi -> $LIBDIR/fribidi"
}

build_abseil() {
  local v; v="$(dep_version ABSEIL_VERSION)"
  fetch "abseil-cpp-$v.tar.gz" "https://github.com/abseil/abseil-cpp/releases/download/$v/abseil-cpp-$v.tar.gz"
  local src; src="$(extract "abseil-cpp-$v.tar.gz" abseil)"
  cmake_install "$src" abseil -DBUILD_SHARED_LIBS=ON -DABSL_PROPAGATE_CXX_STD=ON
}

build_spirv_reflect() {
  local v; v="$(dep_version VULKAN_VERSION)"
  fetch "spirv-reflect-$v.tar.gz" "https://github.com/KhronosGroup/SPIRV-Reflect/archive/refs/tags/vulkan-sdk-$v.tar.gz"
  local src; src="$(extract "spirv-reflect-$v.tar.gz" spirv-reflect)"
  cmake_install "$src" spirv_reflect \
    -DSPIRV_REFLECT_EXECUTABLE=OFF -DSPIRV_REFLECT_EXAMPLES=OFF \
    -DSPIRV_REFLECT_STATIC_LIB=ON
}

build_lzma() {
  local v; v="$(dep_version LZMA_VERSION)"
  fetch "xz-$v.tar.bz2" "https://tukaani.org/xz/xz-$v.tar.bz2"
  local src; src="$(extract "xz-$v.tar.bz2" lzma)"
  autotools_install "$src" lzma --disable-static --enable-shared \
    --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts
}

build_bzip2() {
  local v; v="$(dep_version BZIP2_VERSION)"
  fetch "bzip2-$v.tar.gz" "https://sourceware.org/pub/bzip2/bzip2-$v.tar.gz"
  local src; src="$(extract "bzip2-$v.tar.gz" bzip2)"
  # bzip2 has no configure; compile libbz2 directly with the NDK.
  local cc="$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang"
  local srcs="blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c"
  ( cd "$src" &&
    $cc -fPIC -O2 -c $srcs &&
    $cc -shared -Wl,-soname,libbz2.so.1.0 -o libbz2.so.1.0.8 *.o &&
    mkdir -p "$LIBDIR/bzip2/lib" "$LIBDIR/bzip2/include" &&
    cp libbz2.so.1.0.8 "$LIBDIR/bzip2/lib/libbz2.so" &&
    cp bzlib.h "$LIBDIR/bzip2/include/" )
  echo "[deps] installed bzip2 -> $LIBDIR/bzip2"
}

build_xml2() {
  local v; v="$(dep_version XML2_VERSION)"
  local mm="${v%.*}"  # 2.14
  fetch "libxml2-$v.tar.xz" "https://download.gnome.org/sources/libxml2/$mm/libxml2-$v.tar.xz"
  local src; src="$(extract "libxml2-$v.tar.xz" xml2)"
  cmake_install "$src" xml2 \
    -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF \
    -DLIBXML2_WITH_LZMA=ON -DLIBXML2_WITH_ZLIB=ON \
    -DLIBXML2_WITH_TESTS=OFF -DBUILD_SHARED_LIBS=ON
}

build_vulkan_headers() {
  local v; v="$(dep_version VULKAN_VERSION)"
  fetch "vulkan-headers-$v.tar.gz" "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-$v.0.tar.gz"
  local src; src="$(extract "vulkan-headers-$v.tar.gz" vulkan-headers)"
  cmake_install "$src" vulkan
}

# Draco, for compressed glTF. The io_scene_gltf2 add-on dlopens
# bf_intern_draco_bridge for it; most .glb files published in the wild are
# Draco-compressed, so without this they import as empty meshes.
build_draco() {
  local v; v="$(dep_version DRACO_VERSION)"
  fetch "draco-$v.zip" "https://github.com/google/draco/archive/refs/tags/$v.zip"
  local dir="$WORK_DIR/draco"; rm -rf "$dir"; mkdir -p "$dir"
  ( cd "$dir" && unzip -q "$DL_DIR/draco-$v.zip" && mv draco-*/* . )
  # Static, like meshoptimizer: the bridge that links it lives in the runtime
  # payload rather than the native library directory, so a shared libdraco
  # would not be on the loader path when the add-on dlopens the bridge.
  cmake_install "$dir" draco -DBUILD_SHARED_LIBS=OFF
}

# certifi is what decides whether HTTPS works at all on the device. Blender's
# CMake looks for `certifi/cacert.pem` (find_python_module_file) and only then
# defines PYTHON_SSL_CERT_FILE, which is what makes bpy_interface.cc set
# SSL_CERT_FILE at startup. Without it OpenSSL falls back to the directory it
# was configured with -- $LIBDIR/openssl/ssl -- a build-machine path that does
# not exist on a phone, so every certificate verification fails.
# Pure Python plus a PEM bundle, so the host interpreter can install it
# straight into the target tree; there is nothing to cross-compile.
build_certifi() {
  local v; v="$(dep_version CERTIFI_VERSION)"
  local site="$LIBDIR/python/lib/python3.13/site-packages"
  "$(host_python)" -m pip install -q --no-deps --no-compile --upgrade \
    --target "$site" "certifi==$v"
  local pem="$site/certifi/cacert.pem"
  if [ ! -f "$pem" ]; then
    echo "[deps] ERROR: certifi $v installed but $pem is missing" >&2
    return 1
  fi

  # Setting SSL_CERT_FILE is not enough on its own here. Measured on device:
  # ssl.get_default_verify_paths() reports the bundle, the file is present, and
  # yet SSLContext.set_default_verify_paths() ends up with an empty trust store,
  # so every verification fails with "unable to get local issuer certificate".
  # Loading the very same file explicitly yields all 143 certificates and the
  # request succeeds, so this build's libcrypto is not honouring the variable.
  # Rather than depend on that lookup, make load_default_certs() read the bundle
  # directly. site.py imports this at interpreter start, which covers both
  # Blender's embedded interpreter and the child processes the extension system
  # spawns.
  cat >"$site/sitecustomize.py" <<'SITECUSTOMIZE'
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Generated by build_files/android/deps/build.sh (build_certifi).
"""Make the bundled CA bundle the default TLS trust store.

OpenSSL's own SSL_CERT_FILE lookup has no effect in this Android build, so
without this every HTTPS request fails to verify. See the comment in
build_certifi() for the measurements behind it.
"""

import os

_cert = os.environ.get("SSL_CERT_FILE")
if _cert and os.path.isfile(_cert):
    try:
        import ssl as _ssl

        _load_default_certs_orig = _ssl.SSLContext.load_default_certs

        def _load_default_certs(self, purpose=_ssl.Purpose.SERVER_AUTH):
            try:
                self.load_verify_locations(cafile=_cert)
            except Exception:
                # Keep the stock behaviour rather than leaving an empty store.
                _load_default_certs_orig(self, purpose)

        _ssl.SSLContext.load_default_certs = _load_default_certs
    except Exception:
        # A Python without _ssl still has to start; TLS simply stays unavailable.
        pass
SITECUSTOMIZE

  echo "[deps] installed certifi $v -> $pem"
  echo "[deps] wrote $site/sitecustomize.py (default trust store)"
}

# pip, which desktop Blender ships in its Python's site-packages. Add-ons rely
# on it being importable (`python -m pip install ...`) to pull their own
# dependencies, and without it they fail with "No module named pip".
#
# The target interpreter was configured without --with-ensurepip, and running
# ensurepip on the device fails, so install the wheel into the target tree from
# the host instead. pip is pure Python (py3-none-any), so there is nothing
# architecture-specific about the copy.
#
# What this does *not* change: the wheels PyPI can offer. The target reports
# `android-31-arm64_v8a`, a platform tag almost nothing publishes for, and
# there is no compiler on the device to fall back on. Pure-Python packages
# install; anything with a C extension has to be cross-compiled here the way
# numpy was.
build_pip() {
  local v; v="$(dep_version PYTHON_PIP_VERSION)"
  local site="$LIBDIR/python/lib/python3.13/site-packages"
  "$(host_python)" -m pip install -q --no-deps --no-compile --upgrade \
    --target "$site" "pip==$v"
  if [ ! -f "$site/pip/__main__.py" ]; then
    echo "[deps] ERROR: pip $v installed but $site/pip/__main__.py is missing" >&2
    return 1
  fi
  echo "[deps] installed pip $v -> $site/pip"
}

# The pure-Python packages desktop Blender ships for its HTTP downloader, which the remote asset
# libraries -- Online Essentials among them -- are listed and fetched through
# (`_bpy_internal/http/downloader.py`, which imports requests and cattrs at module level).
# Versions follow build_environment/cmake/versions.cmake. All of them publish py3-none-any
# wheels; `--platform any --only-binary` makes pip take those, rather than the host's compiled
# charset_normalizer, which would not load on the device.
build_remote_asset_python_deps() {
  local site="$LIBDIR/python/lib/python3.13/site-packages"
  local pkg
  local specs=()
  for pkg in REQUESTS:requests URLLIB3:urllib3 IDNA:idna CHARSET_NORMALIZER:charset_normalizer \
             ATTRS:attrs CATTRS:cattrs TYPING_EXTENSIONS:typing_extensions; do
    specs+=("${pkg#*:}==$(dep_version "${pkg%%:*}_VERSION")")
  done
  "$(host_python)" -m pip install -q --no-deps --no-compile --upgrade \
    --platform any --python-version 3.13 --implementation py --abi none --only-binary=:all: \
    --target "$site" "${specs[@]}"
  for pkg in requests urllib3 idna charset_normalizer attr cattrs; do
    if [ ! -f "$site/$pkg/__init__.py" ]; then
      echo "[deps] ERROR: $pkg missing from $site after install" >&2
      return 1
    fi
  done
  echo "[deps] installed ${specs[*]} -> $site"
}

build_numpy() {
  local v; v="$(dep_version NUMPY_VERSION)"
  fetch "numpy-$v.tar.gz" "https://github.com/numpy/numpy/releases/download/v$v/numpy-$v.tar.gz"
  local src; src="$(extract "numpy-$v.tar.gz" numpy)"

  # A host python 3.13 with pip drives the cross-build.
  local host_py; host_py="$(host_python)"
  local venv="$WORK_DIR/numpy-buildenv"
  if [ ! -x "$venv/bin/python" ]; then
    "$host_py" -m venv "$venv"
    "$venv/bin/pip" install -q --upgrade pip cython meson-python ninja
  fi

  # Meson cross file for the NDK.
  local cross="$WORK_DIR/numpy-cross.ini"
  cat >"$cross" <<EOF
[binaries]
c = '$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang'
cpp = '$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang++'
ar = '$ANDROID_LLVM_BIN/llvm-ar'
strip = '$ANDROID_LLVM_BIN/llvm-strip'
pkg-config = '$(command -v pkg-config)'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
longdouble_format = 'IEEE_QUAD_LE'
EOF

  # Make the host interpreter report the TARGET python's sysconfig, so the
  # C extensions are built for Android (the iOS-branch technique).
  export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__android_aarch64-linux-android
  export PYTHONPATH="$LIBDIR/python/lib/python3.13"
  export PATH="$venv/bin:$ANDROID_LLVM_BIN:$PATH"  # meson finds cython + compilers
  export PKG_CONFIG_LIBDIR="$LIBDIR/python/lib/pkgconfig"  # target python .pc
  "$venv/bin/python" -m pip install --no-build-isolation \
    --target="$LIBDIR/python/lib/python3.13/site-packages" \
    -Csetup-args=--cross-file="$cross" \
    -Csetup-args=-Dallow-noblas=true \
    "$src"
  unset _PYTHON_SYSCONFIGDATA_NAME PYTHONPATH
  echo "[deps] installed numpy -> $LIBDIR/python/lib/python3.13/site-packages"
}

build_shaderc() {
  local v; v="$(dep_version SHADERC_VERSION)"  # v2025.4
  fetch "shaderc-$v.tar.gz" "https://github.com/google/shaderc/archive/$v.tar.gz"
  local src; src="$(extract "shaderc-$v.tar.gz" shaderc)"
  # shaderc pulls glslang/SPIRV-Tools/SPIRV-Headers into third_party/.
  ( cd "$src" && /usr/bin/python3 utils/git-sync-deps )
  cmake_install "$src" shaderc \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
    -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DBUILD_SHARED_LIBS=OFF -DSHADERC_ENABLE_SHARED_CRT=ON
  # Blender 5.3 includes spirv/unified1/spirv.h to edit SPIR-V binaries (vk_shader_compiler.cc).
  # The desktop library packages ship SPIRV-Headers inside shaderc's include directory; shaderc's
  # own install does not, so put the copy it was built against in the same place.
  mkdir -p "$LIBDIR/shaderc/include"
  cp -r "$src/third_party/spirv-headers/include/spirv" "$LIBDIR/shaderc/include/"
}

build_meshoptimizer() {
  local v; v="$(dep_version MESHOPTIMIZER_VERSION)"
  fetch "meshoptimizer-$v.zip" "https://github.com/zeux/meshoptimizer/archive/refs/tags/v$v.zip"
  local dir="$WORK_DIR/meshoptimizer"; rm -rf "$dir"; mkdir -p "$dir"
  ( cd "$dir" && unzip -q "$DL_DIR/meshoptimizer-$v.zip" && mv meshoptimizer-*/* . )
  cmake_install "$dir" meshoptimizer -DMESHOPT_BUILD_SHARED_LIBS=OFF
}

build_materialx() {
  local v; v="$(dep_version MATERIALX_VERSION)"
  fetch "materialx-$v.tar.gz" "https://github.com/AcademySoftwareFoundation/MaterialX/archive/refs/tags/v$v.tar.gz"
  local src; src="$(extract "materialx-$v.tar.gz" materialx)"
  cmake_install "$src" materialx \
    -DMATERIALX_BUILD_SHARED_LIBS=ON \
    -DMATERIALX_BUILD_PYTHON=OFF \
    -DMATERIALX_BUILD_TESTS=OFF \
    -DMATERIALX_BUILD_VIEWER=OFF \
    -DMATERIALX_BUILD_GRAPH_EDITOR=OFF \
    -DMATERIALX_BUILD_RENDER=OFF \
    -DMATERIALX_INSTALL_RESOURCES=OFF
}

build_embree() {
  local v; v="$(dep_version EMBREE_VERSION)"
  fetch "embree-$v.zip" "https://github.com/RenderKit/embree/archive/v$v.zip"
  local dir="$WORK_DIR/embree"; rm -rf "$dir"; mkdir -p "$dir"
  ( cd "$dir" && unzip -q "$DL_DIR/embree-$v.zip" && mv embree-*/* . )
  cmake_install "$dir" embree \
    -DTBB_ROOT="$LIBDIR/tbb" \
    -DTBB_DIR="$LIBDIR/tbb/lib/cmake/TBB" \
    -DEMBREE_TBB_ROOT="$LIBDIR/tbb" \
    -DEMBREE_TASKING_SYSTEM=TBB \
    -DEMBREE_ISPC_SUPPORT=OFF \
    -DEMBREE_TUTORIALS=OFF \
    -DEMBREE_STATIC_LIB=OFF \
    -DEMBREE_MAX_ISA=NEON
}

build_alembic() {
  local v; v="$(dep_version ALEMBIC_VERSION)"
  fetch "alembic-$v.tar.gz" "https://github.com/alembic/alembic/archive/$v.tar.gz"
  local src; src="$(extract "alembic-$v.tar.gz" alembic)"
  cmake_install "$src" alembic \
    -DUSE_HDF5=OFF -DUSE_TESTS=OFF -DUSE_BINARIES=OFF \
    -DALEMBIC_SHARED_LIBS=ON -DALEMBIC_ILMBASE_LINK_STATIC=OFF
}

build_openexr() {
  local v; v="$(dep_version OPENEXR_VERSION)"
  fetch "openexr-$v.tar.gz" "https://github.com/AcademySoftwareFoundation/openexr/archive/v$v.tar.gz"
  local src; src="$(extract "openexr-$v.tar.gz" openexr)"
  cmake_install "$src" openexr \
    -DCMAKE_PREFIX_PATH="$LIBDIR/imath;$LIBDIR/deflate;$LIBDIR/zlib" \
    -DBUILD_SHARED_LIBS=ON \
    -DOPENEXR_BUILD_TOOLS=OFF \
    -DOPENEXR_INSTALL_TOOLS=OFF \
    -DOPENEXR_INSTALL_EXAMPLES=OFF \
    -DOPENEXR_BUILD_EXAMPLES=OFF
}

# ISPC is a *host* compiler: Open Image Denoise's CPU kernels are written in
# ISPC and have no C++ fallback. The official x86-64 build emits aarch64 code
# for Android (see `ispc --support-matrix`), so a prebuilt release is enough --
# no source build. It lives outside $LIBDIR because everything in there is a
# target artifact that platform_android.cmake globs onto CMAKE_PREFIX_PATH.
build_ispc() {
  local v; v="$(dep_version ISPC_VERSION)"  # already carries the leading "v"
  local asset
  case "$(uname -s)-$(uname -m)" in
    Darwin-*)        asset="ispc-$v-macOS.universal.tar.gz" ;;
    Linux-aarch64)   asset="ispc-$v-linux.aarch64.tar.gz" ;;
    Linux-*)         asset="ispc-$v-linux.tar.gz" ;;
    *) echo "[deps] ERROR: no prebuilt ISPC for $(uname -s)-$(uname -m)" >&2; return 1 ;;
  esac
  fetch "$asset" "https://github.com/ispc/ispc/releases/download/$v/$asset"
  local dest="$HOST_TOOLS_DIR/ispc"
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xf "$DL_DIR/$asset" -C "$dest" --strip-components=1
  "$dest/bin/ispc" --version
  echo "[deps] installed ispc (host tool) -> $dest"
}

# Open Image Denoise. Built as a static library on purpose: in the default
# shared layout the CPU device is a separate module that libOpenImageDenoise
# dlopen()s by an absolute path derived from its own, under a versioned
# filename (libOpenImageDenoise_device_cpu.so.2.5.0). Android's package
# manager only installs files matching lib*.so from an APK, and package.sh
# only follows NEEDED entries, which a dlopen'ed module is not. Linking
# statically removes the module loader from the picture entirely.
build_oidn() {
  local v; v="$(dep_version OIDN_VERSION)"
  fetch "oidn-$v.src.tar.gz" \
    "https://github.com/RenderKit/oidn/releases/download/v$v/oidn-$v.src.tar.gz"
  local src; src="$(extract "oidn-$v.src.tar.gz" oidn)"

  patch -p1 -d "$src" \
    < "$REPO_ROOT/build_files/build_environment/patches/oidn_android.diff"

  # The "large" RT weights are 23 MB of the 45 MB weight set and back only the
  # High quality preset, which a phone CPU cannot run at a usable speed anyway.
  # UNetFilter::getWeights() falls back to the base model when large is null,
  # so dropping them degrades quality rather than breaking anything. Set
  # OIDN_ANDROID_LARGE_WEIGHTS=1 to keep them.
  if [ "${OIDN_ANDROID_LARGE_WEIGHTS:-0}" != 1 ]; then
    sed_i -E '/weights\/rt_(hdr_calb_cnrm|alb|nrm)_large\.tza/d' "$src/CMakeLists.txt"
    sed_i -E '/#include "weights\/rt_(hdr_calb_cnrm|alb|nrm)_large\.h"/d' \
      "$src/core/rt_filter.cpp"
    sed_i -E 's/blobs::weights::rt_(hdr_calb_cnrm|alb|nrm)_large/nullptr/' \
      "$src/core/rt_filter.cpp"
  fi

  # ISPC has no notion of the CMake toolchain, so the target OS and the ISA
  # baseline are passed through the flags variable the macro already forwards.
  # cortex-a55 is the ARMv8.2-A little core of every big.LITTLE SoC we target;
  # it is what supplies the half-float and dot-product instructions OIDN's
  # ARM64 kernels assume, and code built for it also runs on the big cores.
  local ispc_cpu="${OIDN_ISPC_CPU:-cortex-a55}"

  cmake_install "$src" openimagedenoise \
    -DOIDN_STATIC_LIB=ON \
    -DOIDN_LIBRARY_VERSIONED=OFF \
    -DOIDN_DEVICE_CPU=ON \
    -DOIDN_DEVICE_SYCL=OFF \
    -DOIDN_DEVICE_CUDA=OFF \
    -DOIDN_DEVICE_HIP=OFF \
    -DOIDN_DEVICE_METAL=OFF \
    -DOIDN_FILTER_RT=ON \
    -DOIDN_FILTER_RTLIGHTMAP=OFF \
    -DOIDN_APPS=OFF \
    -DOIDN_INSTALL_DEPENDENCIES=OFF \
    -DTBB_ROOT="$LIBDIR/tbb" \
    -DTBB_DIR="$LIBDIR/tbb/lib/cmake/TBB" \
    -DISPC_EXECUTABLE="$HOST_TOOLS_DIR/ispc/bin/ispc" \
    -DISPC_FLAGS_RELEASE:STRING="-O3 --target-os=android --cpu=$ispc_cpu" \
    -DPython_EXECUTABLE="$(host_python)" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=BOTH
}

# Dependency order, leaf first. This is a build order, not an alphabetical list:
# lzma and bzip2 come before python so the interpreter picks up _lzma and _bz2,
# and every consumer follows the libraries it links against.
ALL_DEPS=(
  zlib zstd deflate imath fmt tbb openexr png pugixml jpeg brotli ktx freetype
  harfbuzz webp tiff openjpeg expat yamlcpp blosc pystring minizipng
  opencolorio opensubdiv robinmap openimageio embree alembic materialx
  potrace gmp sqlite libffi openssl lzma bzip2 python openvdb ogg vorbis
  theora opus lame aom x265 vpx x264 ffmpeg xml2 eigen sse2neon fribidi
  abseil vulkan_headers meshoptimizer shaderc draco numpy certifi pip remote_asset_python_deps usd llvm rubberband
  ispc oidn
  manifold ceres thorvg haru fftw3 openpgl
)

# Manifold, the newer boolean backend. Upstream defaults WITH_MANIFOLD to ON and
# registers eBooleanModifierSolver_Manifold in the RNA enum with no #ifdef, so the
# solver is listed in the Boolean modifier whether or not it is compiled in -- which
# is why picking it behaved oddly here rather than being absent.
#
# CROSS_SECTION brings in Clipper2 and DOWNLOADS lets the build fetch it mid-configure;
# Blender needs neither, and turning both off keeps this a self-contained build.
build_manifold() {
  local v; v="$(dep_version MANIFOLD_VERSION)"
  fetch "manifold-$v.tar.gz" \
    "https://github.com/elalish/manifold/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "manifold-$v.tar.gz" manifold)"
  cmake_install "$src" manifold \
    -DBUILD_SHARED_LIBS=OFF \
    -DMANIFOLD_JSBIND=OFF \
    -DMANIFOLD_CBIND=OFF \
    -DMANIFOLD_PYBIND=OFF \
    -DMANIFOLD_PAR=ON \
    -DMANIFOLD_CROSS_SECTION=OFF \
    -DMANIFOLD_EXPORT=OFF \
    -DMANIFOLD_DEBUG=OFF \
    -DMANIFOLD_TEST=OFF \
    -DMANIFOLD_DOWNLOADS=OFF \
    -DTRACY_ENABLE=OFF \
    -DTBB_ROOT="$LIBDIR/tbb" \
    -DTBB_DIR="$LIBDIR/tbb/lib/cmake/TBB" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
}

# Ceres, the solver behind libmv -- camera and object motion tracking, and the whole
# Movie Clip editor. gflags and glog are vendored in extern/, and abseil, Eigen and TBB
# are already cross-compiled, so this is the only piece that was missing.
build_ceres() {
  local v; v="$(dep_version CERES_VERSION)"
  fetch "ceres-$v.tar.gz" \
    "https://github.com/ceres-solver/ceres-solver/archive/$v.tar.gz"
  local src; src="$(extract "ceres-$v.tar.gz" ceres)"
  # SuiteSparse, LAPACK and CUDA are all absent on the target; naming them keeps the
  # configure step from probing the host and finding one.
  cmake_install "$src" ceres \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DPROVIDE_UNINSTALL_TARGET=OFF \
    -DUSE_CUDA=OFF \
    -DSUITESPARSE=OFF \
    -DLAPACK=OFF \
    -DEIGENSPARSE=ON \
    -DEigen3_DIR="$LIBDIR/eigen/share/eigen3/cmake" \
    -Dabsl_DIR="$LIBDIR/abseil/lib/cmake/absl" \
    -DTBB_DIR="$LIBDIR/tbb/lib/cmake/TBB" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
}

# ThorVG. Nothing in Blender consumes it yet -- it appears only in versions.cmake and
# the desktop dependency builder, in no platform file and no source -- so this is
# staged for whenever upstream wires it up, not something a feature waits on. SVG
# import for Grease Pencil already works and goes through the vendored extern/nanosvg.
#
# The only Meson project here, so it needs a cross file rather than the NDK's CMake
# toolchain: Meson will not accept --cross-file and a toolchain both, and without one
# it silently builds for the host.
build_thorvg() {
  local v; v="$(dep_version THORVG_SHORT_VERSION)"
  fetch "thorvg-$v.tar.xz" \
    "https://github.com/thorvg/thorvg/releases/download/v$v/thorvg-$v.tar.xz"
  local src; src="$(extract "thorvg-$v.tar.xz" thorvg)"
  local cross="$WORK_DIR/thorvg-android-cross.ini"
  cat > "$cross" <<EOF
[binaries]
c = '$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang'
cpp = '$ANDROID_LLVM_BIN/aarch64-linux-android${ANDROID_API}-clang++'
ar = '$ANDROID_LLVM_BIN/llvm-ar'
strip = '$ANDROID_LLVM_BIN/llvm-strip'
pkg-config = 'false'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
  local build="$src/build-android"
  rm -rf "$build"
  # "extra" is emptied to keep OpenMP out, matching the desktop build.
  meson setup "$build" "$src" \
    --cross-file "$cross" \
    --prefix "$LIBDIR/thorvg" \
    --libdir lib \
    --default-library static \
    --buildtype release \
    -Dloaders=svg \
    -Dextra= \
    -Dtools= \
    -Dtests=false \
    -Dstatic=true
  ninja -C "$build"
  ninja -C "$build" install
  echo "[deps] installed thorvg -> $LIBDIR/thorvg"
}

# libharu, for PDF export from Grease Pencil. Needs zlib and libpng, both already here.
build_haru() {
  local v; v="$(dep_version HARU_VERSION)"
  fetch "libharu-$v.tar.gz" \
    "https://github.com/libharu/libharu/archive/refs/tags/v$v.tar.gz"
  local src; src="$(extract "libharu-$v.tar.gz" haru)"
  cmake_install "$src" haru \
    -DBUILD_SHARED_LIBS=OFF \
    -DLIBHPDF_EXAMPLES=OFF \
    -DLIBHPDF_ENABLE_EXCEPTIONS=ON \
    -DLIBHPDF_SHARED=OFF \
    -DLIBHPDF_STATIC=ON \
    -DZLIB_ROOT="$LIBDIR/zlib" \
    -DPNG_ROOT="$LIBDIR/png" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
}

# FFTW, for the Ocean modifier. FindFftw3.cmake asks for three libraries -- fftw3f,
# fftw3f_threads and fftw3 -- so the source is configured twice, once at each
# precision, into the same prefix. Both passes need --enable-threads; only the float
# one takes --enable-float.
build_fftw3() {
  local v; v="$(dep_version FFTW_VERSION)"
  fetch "fftw-$v.tar.gz" "http://www.fftw.org/fftw-$v.tar.gz"
  local src
  src="$(extract "fftw-$v.tar.gz" fftw3-double)"
  refresh_config_sub "$src"
  autotools_install "$src" fftw3 \
    --enable-static --disable-shared --enable-threads --disable-fortran
  src="$(extract "fftw-$v.tar.gz" fftw3-float)"
  refresh_config_sub "$src"
  autotools_install "$src" fftw3 \
    --enable-static --disable-shared --enable-threads --disable-fortran --enable-float
}

# Open PGL, path guiding for Cycles. Intel's ISA options are all x86; the aarch64 build
# goes through their NEON path, so the x86 ones are named explicitly to keep the
# configure step from asking the compiler for AVX it cannot give.
build_openpgl() {
  local v; v="$(dep_version OPENPGL_VERSION)"
  fetch "openpgl-$v.tar.gz" \
    "https://github.com/OpenPathGuidingLibrary/openpgl/archive/refs/tags/$v.tar.gz"
  local src; src="$(extract "openpgl-$v.tar.gz" openpgl)"
  cmake_install "$src" openpgl \
    -DOPENPGL_BUILD_STATIC=ON \
    -DOPENPGL_BUILD_PYTHON=OFF \
    -DOPENPGL_BUILD_TOOLS=OFF \
    -DOPENPGL_ISA_AVX2=OFF \
    -DOPENPGL_ISA_AVX512=OFF \
    -DOPENPGL_ISA_SSE4=OFF \
    -DOPENPGL_ISA_NEON=ON \
    -DOPENPGL_TBB_ROOT="$LIBDIR/tbb" \
    -DTBB_ROOT="$LIBDIR/tbb" \
    -DTBB_DIR="$LIBDIR/tbb/lib/cmake/TBB" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
}

# Where a dependency lands, when that differs from its name. Without this the
# skip check never matches and the package is rebuilt on every run.
dep_install_dir() {
  case "$1" in
    numpy)          echo "$LIBDIR/python/lib/python3.13/site-packages/numpy" ;;
    certifi)        echo "$LIBDIR/python/lib/python3.13/site-packages/certifi" ;;
    pip)            echo "$LIBDIR/python/lib/python3.13/site-packages/pip" ;;
    vulkan_headers) echo "$LIBDIR/vulkan" ;;
    ispc)           echo "$HOST_TOOLS_DIR/ispc" ;;
    oidn)           echo "$LIBDIR/openimagedenoise" ;;
    *)              echo "$LIBDIR/$1" ;;
  esac
}

# A dependency counts as built when its install directory has something in it.
dep_is_built() {
  local d; d="$(dep_install_dir "$1")"
  [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]
}

# Catch a library that silently came out for the host instead of the target.
dep_check_arch() {
  local lib
  # Host tools are meant to be x86-64; checking them for aarch64 would fail.
  case "$1" in ispc) return 0 ;; esac
  lib=$(ls "$(dep_install_dir "$1")"/lib/*.so "$(dep_install_dir "$1")"/lib/*.a 2>/dev/null | head -1)
  [ -n "$lib" ] || return 0   # header-only packages have nothing to check
  # Do not use grep -q here while pipefail is active: on archives it exits
  # after the first object, llvm-objdump receives SIGPIPE, and a valid arm64
  # archive is then reported as a failure.
  if ! "$ANDROID_LLVM_BIN/llvm-objdump" -f "$lib" 2>/dev/null | grep aarch64 >/dev/null; then
    echo "[deps] ERROR: $1 did not build for aarch64" >&2
    return 1
  fi
}

main() {
  [ $# -gt 0 ] || {
    echo "usage: $0 <dep> [dep...]" >&2
    echo "       $0 all [--force]   build everything in order, skipping what exists" >&2
    exit 1
  }

  local targets=("$@") force=0
  if [ "${1:-}" = all ]; then
    targets=("${ALL_DEPS[@]}")
    [ "${2:-}" = --force ] && force=1
  fi

  local total=${#targets[@]} n=0 built=0 skipped=0
  for t in "${targets[@]}"; do
    n=$((n + 1))
    if [ "$force" -eq 0 ] && [ "${1:-}" = all ] && dep_is_built "$t"; then
      echo "[$n/$total] $t: already built, skipping"
      skipped=$((skipped + 1))
      continue
    fi
    echo "=== [$n/$total] building: $t ==="
    "build_$t"
    dep_check_arch "$t" || exit 1
    built=$((built + 1))
  done

  [ "${1:-}" = all ] && echo "[deps] done: $built built, $skipped already present"
  return 0
}

main "$@"
