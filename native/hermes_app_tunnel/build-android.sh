#!/usr/bin/env bash
# Host-owned Hermes native asset. No SDK downloads or global configuration writes.
set -euo pipefail
crate_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$crate_dir/../.." && pwd)"
out_dir=""
abis="arm64-v8a"
while (($#)); do
  case "$1" in
    --out-dir) out_dir="$2"; shift 2 ;;
    --abis) abis="$2"; shift 2 ;;
    *) echo 'usage: build-android.sh --out-dir DIRECTORY [--abis arm64-v8a,x86_64,armeabi-v7a]' >&2; exit 2 ;;
  esac
done
[[ -n "$out_dir" ]] || { echo '--out-dir is required' >&2; exit 2; }
android_sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$android_sdk_dir" && -f "$repo_dir/client/android/local.properties" ]]; then
  android_sdk_dir="$(sed -n 's/^sdk\.dir=//p' "$repo_dir/client/android/local.properties" | head -n 1)"
fi
[[ -d "$android_sdk_dir/ndk" ]] || { echo 'Android SDK with an installed NDK is required' >&2; exit 1; }
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  hermes_ndk="$ANDROID_NDK_HOME"
else
  hermes_ndk="$android_sdk_dir/ndk/$(find "$android_sdk_dir/ndk" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)"
fi
case "$(uname -s)" in
  Linux) ndk_host=linux-x86_64 ;;
  Darwin) ndk_host=darwin-x86_64 ;;
  *) echo 'Hermes Android builds require a Linux/macOS NDK host' >&2; exit 1 ;;
esac
ndk_bin="$hermes_ndk/toolchains/llvm/prebuilt/$ndk_host/bin"
[[ -d "$ndk_bin" ]] || { echo 'NDK toolchain is missing' >&2; exit 1; }
IFS=',' read -ra requested_abis <<< "$abis"
for abi in "${requested_abis[@]}"; do
  case "$abi" in
    arm64-v8a) target=aarch64-linux-android; compiler=aarch64-linux-android21-clang ;;
    x86_64) target=x86_64-linux-android; compiler=x86_64-linux-android21-clang ;;
    armeabi-v7a) target=armv7-linux-androideabi; compiler=armv7a-linux-androideabi21-clang ;;
    *) echo "Unsupported Hermes Android ABI: $abi" >&2; exit 1 ;;
  esac
  rustup target list --installed | rg -qx "$target" || { echo "Install Rust target $target before building" >&2; exit 1; }
  [[ -x "$ndk_bin/$compiler" ]] || { echo 'NDK clang executable is missing' >&2; exit 1; }
  linker_key="CARGO_TARGET_$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')_LINKER"
  cc_key="CC_${target//-/_}"
  ar_key="AR_${target//-/_}"
  env "$linker_key=$ndk_bin/$compiler" "$cc_key=$ndk_bin/$compiler" "$ar_key=$ndk_bin/llvm-ar" \
    cargo build --manifest-path "$crate_dir/Cargo.toml" --locked --release --target "$target" -p elecon-hermes-app-tunnel
  mkdir -p "$out_dir/$abi"
  cp "$crate_dir/target/$target/release/libelecon_hermes.so" "$out_dir/$abi/libelecon_hermes.so"
done
