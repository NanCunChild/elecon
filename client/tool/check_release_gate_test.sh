#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/payload/flutter_assets/packages/liquid_glass_widgets/shaders"
touch "$TMP/payload/flutter_assets/packages/liquid_glass_widgets/shaders/liquid_glass_test.frag"
(
  cd "$TMP/payload"
  zip -qr "$TMP/contains-liquid-glass.apk" .
)

if output="$(
  cd "$ROOT"
  ELECON_RELEASE_GATE_APK="$TMP/contains-liquid-glass.apk" bash tool/check_release_gate.sh 2>&1
)"; then
  echo "含 Apple-only shader 的 APK 被错误放行" >&2
  exit 1
fi

if [[ "$output" != *"release APK 仍包含 Apple-only 液态玻璃资源"* ]]; then
  echo "APK 被拒原因不正确：$output" >&2
  exit 1
fi

echo "release gate 负例通过：Apple-only shader APK 被拒"
