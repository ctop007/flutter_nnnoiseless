#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust"
LIB_NAME="hzh_noise"
ANDROID_JNI_DIR="$ROOT_DIR/android/src/main/jniLibs"
IOS_FRAMEWORKS_DIR="$ROOT_DIR/ios/Frameworks"
IOS_INCLUDE_DIR="$IOS_FRAMEWORKS_DIR/include"
IOS_XCFRAMEWORK_DIR="$IOS_FRAMEWORKS_DIR/${LIB_NAME}.xcframework"

ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
ANDROID_TOOLCHAIN_DIR=""
if [[ -n "$ANDROID_NDK_HOME" ]]; then
  if [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin" ]]; then
    ANDROID_TOOLCHAIN_DIR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
  else
    ANDROID_TOOLCHAIN_DIR="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -maxdepth 1 -type d | head -n 1)/bin"
  fi
fi

build_android_target() {
  local rust_target="$1"
  local android_abi="$2"
  local linker_name="$3"
  local linker_path="$ANDROID_TOOLCHAIN_DIR/$linker_name"

  if [[ ! -x "$linker_path" ]]; then
    echo "Missing Android linker: $linker_path" >&2
    exit 1
  fi

  local env_name
  env_name="CARGO_TARGET_$(printf '%s' "$rust_target" | tr '[:lower:]' '[:upper:]')_LINKER"
  env_name="${env_name//-/_}"

  echo "Building Android target $rust_target -> $android_abi"
  env "$env_name=$linker_path" \
    cargo build \
      --manifest-path "$RUST_DIR/Cargo.toml" \
      -p "$LIB_NAME" \
      --target "$rust_target" \
      --release

  mkdir -p "$ANDROID_JNI_DIR/$android_abi"
  cp \
    "$RUST_DIR/target/$rust_target/release/lib${LIB_NAME}.so" \
    "$ANDROID_JNI_DIR/$android_abi/lib${LIB_NAME}.so"
}

build_ios_target() {
  local rust_target="$1"
  local sdk="$2"

  echo "Building iOS target $rust_target ($sdk)"
  SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    cargo build \
      --manifest-path "$RUST_DIR/Cargo.toml" \
      -p "$LIB_NAME" \
      --target "$rust_target" \
      --release
}

build_android() {
  if [[ -z "$ANDROID_NDK_HOME" || ! -d "$ANDROID_NDK_HOME" ]]; then
    echo "ANDROID_NDK_HOME or ANDROID_NDK_ROOT must point to a valid NDK." >&2
    exit 1
  fi

  build_android_target "armv7-linux-androideabi" "armeabi-v7a" "armv7a-linux-androideabi21-clang"
  build_android_target "aarch64-linux-android" "arm64-v8a" "aarch64-linux-android21-clang"
  build_android_target "i686-linux-android" "x86" "i686-linux-android21-clang"
  build_android_target "x86_64-linux-android" "x86_64" "x86_64-linux-android21-clang"
}

build_ios() {
  mkdir -p "$IOS_INCLUDE_DIR"
  cat > "$IOS_INCLUDE_DIR/${LIB_NAME}.h" <<'EOF'
#ifndef HZH_NOISE_H
#define HZH_NOISE_H

#include <stdint.h>
#include <stddef.h>

typedef struct FfiByteBuffer {
  uint8_t *ptr;
  size_t len;
  int32_t code;
} FfiByteBuffer;

uint32_t nnnoiseless_target_sample_rate(void);
size_t nnnoiseless_frame_size(void);
size_t nnnoiseless_stream_recommended_input_bytes(uint32_t input_sample_rate, uint32_t num_channels);
int32_t nnnoiseless_denoise_file(const char *input_path, const char *output_path);
void *nnnoiseless_stream_create(uint32_t input_sample_rate, uint32_t num_channels);
FfiByteBuffer nnnoiseless_stream_process(void *stream, const uint8_t *input_ptr, size_t input_len);
FfiByteBuffer nnnoiseless_stream_flush(void *stream);
void nnnoiseless_stream_destroy(void *stream);
void nnnoiseless_buffer_free(uint8_t *ptr, size_t len);
char *nnnoiseless_last_error_message(void);
void nnnoiseless_string_free(char *ptr);

#endif
EOF

  build_ios_target "aarch64-apple-ios" "iphoneos"
  build_ios_target "aarch64-apple-ios-sim" "iphonesimulator"
  build_ios_target "x86_64-apple-ios" "iphonesimulator"

  local simulator_temp_dir="$IOS_FRAMEWORKS_DIR/simulator-universal"
  local simulator_universal="$simulator_temp_dir/lib${LIB_NAME}.a"
  rm -rf "$simulator_temp_dir"
  mkdir -p "$simulator_temp_dir"
  lipo -create \
    "$RUST_DIR/target/aarch64-apple-ios-sim/release/lib${LIB_NAME}.a" \
    "$RUST_DIR/target/x86_64-apple-ios/release/lib${LIB_NAME}.a" \
    -output "$simulator_universal"

  rm -rf "$IOS_XCFRAMEWORK_DIR"
  xcodebuild -create-xcframework \
    -library "$RUST_DIR/target/aarch64-apple-ios/release/lib${LIB_NAME}.a" \
    -headers "$IOS_INCLUDE_DIR" \
    -library "$simulator_universal" \
    -headers "$IOS_INCLUDE_DIR" \
    -output "$IOS_XCFRAMEWORK_DIR"

  rm -rf "$simulator_temp_dir"
}

main() {
  cd "$ROOT_DIR"
  rm -rf "$ANDROID_JNI_DIR" "$IOS_FRAMEWORKS_DIR"
  build_android
  build_ios
  echo "Prebuilt mobile binaries updated."
}

main "$@"
