#!/usr/bin/env bash
# release 构建阀门：防止 debug-only 权限/配置导致 release 无法出网/登录。
#
# 用法（在 client/ 下）:
#   bash tool/check_release_gate.sh              # 静态检查 + release APK
#   bash tool/check_release_gate.sh --static-only # 仅静态（本地快速）
#
# 退出码非 0 = 闸门失败。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STATIC_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --static-only) STATIC_ONLY=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "[release-gate] 未知参数: $arg" >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "[release-gate] ✗ $*" >&2
  exit 1
}

ok() {
  echo "[release-gate] ✓ $*"
}

MAIN_MANIFEST="android/app/src/main/AndroidManifest.xml"
[[ -f "$MAIN_MANIFEST" ]] || fail "缺少 $MAIN_MANIFEST"

# —— 1. main（release 合并基线）必须声明 INTERNET ——
# 历史事故：只写在 debug/profile，导致 --release APK 无法 WebView 登录 / DirectTransport。
if ! grep -qE 'android\.permission\.INTERNET' "$MAIN_MANIFEST"; then
  fail "$MAIN_MANIFEST 未声明 android.permission.INTERNET（release 无网）"
fi
ok "main AndroidManifest 声明 INTERNET"

# —— 2. 不得把 INTERNET 仅放在 debug/profile 作为「唯一来源」的误导注释误用 ——
# （main 已有即可；再确认 debug 未用 tools:node="remove" 剥掉 INTERNET）
for flavor in debug profile; do
  f="android/app/src/${flavor}/AndroidManifest.xml"
  [[ -f "$f" ]] || continue
  if grep -qE 'tools:node\s*=\s*"remove"' "$f" && grep -qE 'INTERNET' "$f"; then
    fail "$f 可能用 tools:node=remove 剥离 INTERNET"
  fi
done
ok "debug/profile 未剥离 INTERNET"

# —— 3. release 实际构建 + 产物权限（可选跳过）——
if [[ "$STATIC_ONLY" -eq 1 ]]; then
  ok "静态检查通过（--static-only，跳过 APK 构建）"
  exit 0
fi

command -v flutter >/dev/null 2>&1 || fail "未找到 flutter"

echo "[release-gate] flutter build apk --release …"
flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK" ]] || fail "未产出 $APK"
ok "产出 release APK: $APK"

# 优先 aapt dump permissions；无 Android SDK 时回退：解压 binary manifest 不可靠，改用
# apkanalyzer / aapt2；再不行至少确认 APK 体积非空。
dump_perms() {
  local apk="$1"
  if command -v aapt >/dev/null 2>&1; then
    aapt dump permissions "$apk"
    return 0
  fi
  local build_tools=""
  if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/build-tools" ]]; then
    build_tools="$(ls -1d "$ANDROID_HOME/build-tools"/* 2>/dev/null | sort -V | tail -1 || true)"
  elif [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT/build-tools" ]]; then
    build_tools="$(ls -1d "$ANDROID_SDK_ROOT/build-tools"/* 2>/dev/null | sort -V | tail -1 || true)"
  fi
  if [[ -n "$build_tools" && -x "$build_tools/aapt" ]]; then
    "$build_tools/aapt" dump permissions "$apk"
    return 0
  fi
  if command -v aapt2 >/dev/null 2>&1; then
    # aapt2 dump permissions 接口因版本而异，失败则交给调用方
    aapt2 dump permissions "$apk" 2>/dev/null && return 0
  fi
  return 1
}

if perms="$(dump_perms "$APK")"; then
  echo "$perms" | grep -qE 'android\.permission\.INTERNET' \
    || fail "release APK 权限列表中无 INTERNET（aapt dump）"
  ok "release APK 含 INTERNET（aapt）"
else
  # CI 应装 SDK；本地若无 aapt，至少确认 APK 非空且静态门已过
  size="$(wc -c <"$APK" | tr -d ' ')"
  [[ "$size" -gt 1000000 ]] || fail "release APK 异常过小 (${size} bytes)"
  echo "[release-gate] ⚠ 无 aapt，跳过 APK 权限 dump（静态 INTERNET 已通过，APK size=${size}）"
fi

ok "release 闸门通过"
