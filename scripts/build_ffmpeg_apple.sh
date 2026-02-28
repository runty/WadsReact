#!/usr/bin/env bash
set -euo pipefail

# Builds static FFmpeg libraries for Apple platforms and packages them as XCFrameworks
# compatible with a local Swift package at Vendor/FFmpegLocal.
#
# Outputs:
#   Vendor/FFmpegLocal/Artifacts/Libavcodec.xcframework
#   Vendor/FFmpegLocal/Artifacts/Libavformat.xcframework
#   Vendor/FFmpegLocal/Artifacts/Libavutil.xcframework
#
# Usage:
#   scripts/build_ffmpeg_apple.sh
#   FFMPEG_VERSION=7.1 scripts/build_ffmpeg_apple.sh
#
# Notes:
# - This builds LGPL-friendly defaults (no --enable-gpl, no --enable-nonfree).
# - Builds are intentionally conservative (asm disabled) to reduce toolchain friction.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${ROOT_DIR}/.build/ffmpeg"
ARTIFACTS_DIR="${ROOT_DIR}/Vendor/FFmpegLocal/Artifacts"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
FFMPEG_TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_TARBALL}"
FFMPEG_SRC_DIR="${BUILD_ROOT}/src/ffmpeg-${FFMPEG_VERSION}"

LIBS=(avcodec avformat avutil)

mkdir -p "${BUILD_ROOT}" "${ARTIFACTS_DIR}"

fetch_ffmpeg() {
  if [[ -d "${FFMPEG_SRC_DIR}" ]]; then
    return
  fi

  mkdir -p "${BUILD_ROOT}/src"
  local tarball_path="${BUILD_ROOT}/${FFMPEG_TARBALL}"

  if [[ ! -f "${tarball_path}" ]]; then
    echo "Downloading ${FFMPEG_URL}"
    curl -L "${FFMPEG_URL}" -o "${tarball_path}"
  fi

  echo "Extracting ${FFMPEG_TARBALL}"
  tar -xf "${tarball_path}" -C "${BUILD_ROOT}/src"
}

build_one_arch() {
  local platform="$1"      # ios | iossim | macos
  local arch="$2"          # arm64 | x86_64
  local sdk="$3"           # iphoneos | iphonesimulator | macosx
  local min_flag="$4"      # -miphoneos-version-min=... etc
  local out_dir="${BUILD_ROOT}/out/${platform}-${arch}"
  local source_copy="${BUILD_ROOT}/work/${platform}-${arch}/ffmpeg"

  rm -rf "${BUILD_ROOT}/work/${platform}-${arch}"
  mkdir -p "$(dirname "${source_copy}")"
  cp -R "${FFMPEG_SRC_DIR}" "${source_copy}"

  local cc
  cc="$(xcrun --sdk "${sdk}" -f clang)"
  local sysroot
  sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"

  pushd "${source_copy}" >/dev/null

  ./configure \
    --prefix="${out_dir}" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch="${arch}" \
    --cc="${cc}" \
    --sysroot="${sysroot}" \
    --extra-cflags="-arch ${arch} -isysroot ${sysroot} ${min_flag} -fPIC" \
    --extra-ldflags="-arch ${arch} -isysroot ${sysroot} ${min_flag}" \
    --enable-static \
    --disable-shared \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-asm \
    --disable-everything \
    --enable-avcodec \
    --enable-avformat \
    --enable-avutil \
    --enable-protocol=file \
    --enable-demuxer=matroska \
    --enable-demuxer=mov \
    --enable-demuxer=aac \
    --enable-demuxer=mp3 \
    --enable-demuxer=flac \
    --enable-muxer=mp4 \
    --enable-muxer=mov \
    --enable-muxer=ipod \
    --enable-parser=aac \
    --enable-parser=h264 \
    --enable-parser=hevc \
    --enable-bsf=aac_adtstoasc

  make -j"$(sysctl -n hw.ncpu)"
  make install

  popd >/dev/null
}

make_universal() {
  local platform="$1" # ios-simulator | macos
  local out_dir="${BUILD_ROOT}/universal/${platform}"
  local a_dir="$2"
  local b_dir="$3"

  rm -rf "${out_dir}"
  mkdir -p "${out_dir}/lib" "${out_dir}/include"

  for lib in "${LIBS[@]}"; do
    lipo -create \
      "${a_dir}/lib/lib${lib}.a" \
      "${b_dir}/lib/lib${lib}.a" \
      -output "${out_dir}/lib/lib${lib}.a"
  done

  # Use one include tree; headers are architecture-independent.
  cp -R "${a_dir}/include/." "${out_dir}/include/"
}

write_modulemap() {
  local include_dir="$1"
  cat > "${include_dir}/module.modulemap" <<'MODULEMAP'
module Libavutil [system] {
  header "libavutil/avutil.h"
  export *
}
module Libavcodec [system] {
  header "libavcodec/avcodec.h"
  export *
}
module Libavformat [system] {
  header "libavformat/avformat.h"
  export *
}
MODULEMAP
}

create_xcframeworks() {
  local ios_device_dir="${BUILD_ROOT}/out/ios-arm64"
  local ios_sim_dir="${BUILD_ROOT}/universal/ios-simulator"
  local macos_dir="${BUILD_ROOT}/universal/macos"

  write_modulemap "${ios_device_dir}/include"
  write_modulemap "${ios_sim_dir}/include"
  write_modulemap "${macos_dir}/include"

  rm -rf "${ARTIFACTS_DIR}/Libavutil.xcframework" \
         "${ARTIFACTS_DIR}/Libavcodec.xcframework" \
         "${ARTIFACTS_DIR}/Libavformat.xcframework"

  xcodebuild -create-xcframework \
    -library "${ios_device_dir}/lib/libavutil.a" -headers "${ios_device_dir}/include" \
    -library "${ios_sim_dir}/lib/libavutil.a" -headers "${ios_sim_dir}/include" \
    -library "${macos_dir}/lib/libavutil.a" -headers "${macos_dir}/include" \
    -output "${ARTIFACTS_DIR}/Libavutil.xcframework"

  xcodebuild -create-xcframework \
    -library "${ios_device_dir}/lib/libavcodec.a" \
    -library "${ios_sim_dir}/lib/libavcodec.a" \
    -library "${macos_dir}/lib/libavcodec.a" \
    -output "${ARTIFACTS_DIR}/Libavcodec.xcframework"

  xcodebuild -create-xcframework \
    -library "${ios_device_dir}/lib/libavformat.a" \
    -library "${ios_sim_dir}/lib/libavformat.a" \
    -library "${macos_dir}/lib/libavformat.a" \
    -output "${ARTIFACTS_DIR}/Libavformat.xcframework"
}

echo "Preparing FFmpeg source..."
fetch_ffmpeg

echo "Building iOS arm64..."
build_one_arch "ios" "arm64" "iphoneos" "-miphoneos-version-min=15.0"

echo "Building iOS Simulator arm64..."
build_one_arch "iossim" "arm64" "iphonesimulator" "-mios-simulator-version-min=15.0"

echo "Building iOS Simulator x86_64..."
build_one_arch "iossim" "x86_64" "iphonesimulator" "-mios-simulator-version-min=15.0"

echo "Building macOS arm64..."
build_one_arch "macos" "arm64" "macosx" "-mmacosx-version-min=13.0"

echo "Building macOS x86_64..."
build_one_arch "macos" "x86_64" "macosx" "-mmacosx-version-min=13.0"

echo "Creating universal static libs..."
make_universal "ios-simulator" "${BUILD_ROOT}/out/iossim-arm64" "${BUILD_ROOT}/out/iossim-x86_64"
make_universal "macos" "${BUILD_ROOT}/out/macos-arm64" "${BUILD_ROOT}/out/macos-x86_64"

echo "Packaging XCFrameworks..."
create_xcframeworks

echo "Done. Artifacts are in ${ARTIFACTS_DIR}"
