#!/usr/bin/env bash
# Hermetic preflight/build orchestration checks: no SDK, downloads or Rust compilation.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/crate" "$fixture_dir/bin"
cp "$script_dir/build-android.sh" "$fixture_dir/crate/"
case "$(uname -s)" in
  Linux) ndk_host=linux-x86_64 ;;
  Darwin) ndk_host=darwin-x86_64 ;;
  *) echo 'SKIP: requires a supported NDK host'; exit 0 ;;
esac
ndk_bin="$fixture_dir/ndk/toolchains/llvm/prebuilt/$ndk_host/bin"
mkdir -p "$ndk_bin"
for compiler in armv7a-linux-androideabi21-clang aarch64-linux-android21-clang x86_64-linux-android21-clang llvm-ar; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ndk_bin/$compiler"
  chmod +x "$ndk_bin/$compiler"
done
cat > "$fixture_dir/bin/rustup" <<'SH'
#!/usr/bin/env bash
[[ "$*" == 'target list --installed' ]] || exit 99
printf '%s\n' "$HERMES_TEST_TARGETS"
SH
cat > "$fixture_dir/bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERMES_TEST_CARGO_LOG"
while (($#)); do
  case "$1" in
    --manifest-path) crate_dir="$(dirname -- "$2")"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$crate_dir/target/$target/release"
printf '%s\n' "$target" > "$crate_dir/target/$target/release/libelecon_hermes.so"
SH
chmod +x "$fixture_dir/bin/"*
export PATH="$fixture_dir/bin:$PATH"
export HERMES_TEST_TARGETS='aarch64-linux-android'
export HERMES_TEST_CARGO_LOG="$fixture_dir/cargo.log"
script="$fixture_dir/crate/build-android.sh"
expect_failure() {
  if bash "$script" --out-dir "$fixture_dir/out" "$@" > "$fixture_dir/error" 2>&1; then
    echo "Expected failure: $*" >&2; exit 1
  fi
  [[ ! -f "$HERMES_TEST_CARGO_LOG" ]] || { echo 'Cargo ran before all preflight checks passed' >&2; exit 1; }
}
expect_failure --ndk-dir "$fixture_dir/ndk" --abis arm64-v8a,armeabi-v7a,x86_64
grep -qF 'rustup target add armv7-linux-androideabi x86_64-linux-android' "$fixture_dir/error"
expect_failure --ndk-dir "$fixture_dir/ndk" --abis arm64-v8a,invalid
grep -qF 'Unsupported Hermes Android ABI: invalid' "$fixture_dir/error"
expect_failure --ndk-dir "$fixture_dir/ndk" --abis arm64-v8a,
grep -qF 'Empty Hermes Android ABI' "$fixture_dir/error"
expect_failure --ndk-dir
grep -qF 'usage:' "$fixture_dir/error"
# A broken explicit NDK must not silently fall back to a globally installed NDK.
expect_failure --ndk-dir "$fixture_dir/missing"
grep -qF 'NDK toolchain is missing:' "$fixture_dir/error"
export HERMES_TEST_TARGETS=$'aarch64-linux-android\narmv7-linux-androideabi\nx86_64-linux-android'
# Gradle's explicit directory wins even when a different environment value is present.
ANDROID_NDK_HOME="$fixture_dir/missing" bash "$script" --out-dir "$fixture_dir/out" \
  --ndk-dir "$fixture_dir/ndk" --abis arm64-v8a,armeabi-v7a,x86_64
[[ "$(wc -l < "$HERMES_TEST_CARGO_LOG")" -eq 3 ]]
for abi in arm64-v8a armeabi-v7a x86_64; do
  [[ -s "$fixture_dir/out/$abi/libelecon_hermes.so" ]]
done
echo 'Hermes Android build orchestration checks passed'
