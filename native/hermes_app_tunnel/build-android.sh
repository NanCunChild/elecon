#!/usr/bin/env bash
# Host-owned Hermes native asset. No SDK downloads or global configuration writes.
set -euo pipefail
crate_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out_dir=""
abis="arm64-v8a"
hermes_ndk="${ANDROID_NDK_HOME:-}"
usage() {
  echo 'usage: build-android.sh --out-dir DIRECTORY --ndk-dir DIRECTORY [--abis arm64-v8a,x86_64,armeabi-v7a]' >&2
}
while (($#)); do
  case "$1" in
    --out-dir|--abis|--ndk-dir)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage; exit 2; }
      case "$1" in
        --out-dir) out_dir="$2" ;;
        --abis) abis="$2" ;;
        --ndk-dir) hermes_ndk="$2" ;;
      esac
      shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$out_dir" ]] || { echo '--out-dir is required' >&2; exit 2; }
[[ -n "$hermes_ndk" ]] || { echo 'Pass --ndk-dir (Gradle uses its selected NDK), or set ANDROID_NDK_HOME' >&2; exit 2; }
case "$(uname -s)" in
  Linux) ndk_host=linux-x86_64 ;;
  Darwin) ndk_host=darwin-x86_64 ;;
  *) echo 'Hermes Android builds require a Linux/macOS NDK host' >&2; exit 1 ;;
esac
ndk_bin="$hermes_ndk/toolchains/llvm/prebuilt/$ndk_host/bin"
[[ -d "$ndk_bin" ]] || { echo "NDK toolchain is missing: $ndk_bin" >&2; exit 1; }
command -v rustup >/dev/null || { echo 'Install Rust with rustup before building Hermes' >&2; exit 1; }
command -v cargo >/dev/null || { echo 'Install Cargo before building Hermes' >&2; exit 1; }
installed_targets="$(rustup target list --installed)"
IFS=',' read -ra requested_abis <<< "$abis"
[[ "$abis" != ,* && "$abis" != *, && "$abis" != *,,* ]] || { echo 'Empty Hermes Android ABI' >&2; exit 2; }
targets=()
compilers=()
missing_targets=()
# Validate every requested ABI before compiling any of them.
for abi in "${requested_abis[@]}"; do
  case "$abi" in
    arm64-v8a) target=aarch64-linux-android; compiler=aarch64-linux-android21-clang ;;
    x86_64) target=x86_64-linux-android; compiler=x86_64-linux-android21-clang ;;
    armeabi-v7a) target=armv7-linux-androideabi; compiler=armv7a-linux-androideabi21-clang ;;
    *) echo "Unsupported Hermes Android ABI: $abi" >&2; exit 1 ;;
  esac
  targets+=("$target")
  compilers+=("$compiler")
  if ! grep -qxF "$target" <<< "$installed_targets"; then
    missing_targets+=("$target")
  fi
  [[ -x "$ndk_bin/$compiler" && -x "$ndk_bin/llvm-ar" ]] || { echo "NDK compiler/archive tools are missing for $abi" >&2; exit 1; }
done
if ((${#missing_targets[@]})); then
  printf 'Missing Hermes Rust targets. Run: rustup target add' >&2
  printf ' %s' "${missing_targets[@]}" >&2
  printf '\n' >&2
  exit 1
fi
for i in "${!requested_abis[@]}"; do
  abi="${requested_abis[$i]}"
  target="${targets[$i]}"
  compiler="${compilers[$i]}"
  linker_key="CARGO_TARGET_$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')_LINKER"
  cc_key="CC_${target//-/_}"
  ar_key="AR_${target//-/_}"
  env "$linker_key=$ndk_bin/$compiler" "$cc_key=$ndk_bin/$compiler" "$ar_key=$ndk_bin/llvm-ar" \
    cargo build --manifest-path "$crate_dir/Cargo.toml" --locked --release --target "$target" -p elecon-hermes-app-tunnel
  mkdir -p "$out_dir/$abi"
  cp "$crate_dir/target/$target/release/libelecon_hermes.so" "$out_dir/$abi/libelecon_hermes.so"
done
