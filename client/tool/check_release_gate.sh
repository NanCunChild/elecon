#!/usr/bin/env bash
# release 构建阀门：
#   ① 防止 debug-only 权限/配置导致 release 无法出网/登录；
#   ② ADR-024 护栏 4——**分发 / 提交的产物必须是 DEPLOY profile**（无侧载入口）。
#
# ADR-024 §5.3 勾决「二者并用」，本脚本据此对产物做两条独立断言：
#   (a) 符号 grep：DEPLOY 产物中不得出现侧载入口哨兵 ELECON_SIDELOAD_ENTRY_A7F3。
#       这是**结构性**证据——直接验「代码确实不在产物里」，最强的一条。
#   (b) 构建元数据：APK 内 assets/elecon_build_profile.txt 首行必须是 DEPLOY。
#       防 (a) 因混淆/重命名/压缩漏网——两者互补，任一不满足即拒绝分发。
#
# 判别器换位前，`kReleaseMode` 让「提交的必然无侧载」自动成立；换成项目 flag 后
# 这条从「自动为真」变成「须机械查」，就是本节存在的理由（ADR-024 §2.3 护栏 4）。
#
# 用法（在 client/ 下）:
#   bash tool/check_release_gate.sh              # 静态检查 + release APK
#   bash tool/check_release_gate.sh --static-only # 仅静态（本地快速）
#
# 退出码非 0 = 闸门失败。
set -euo pipefail

# 侧载入口哨兵。**必须与 lib/core/trust/trust_profile.dart 的 kSideloadEntryMarker
# 逐字一致**；test/trust_profile_test.dart 钉死 Dart 侧常量值，下面的静态检查钉死
# 两处相等——否则本断言会退化成永远为真的空检查。
SIDELOAD_ENTRY_MARKER="ELECON_SIDELOAD_ENTRY_A7F3"
TRUST_PROFILE_DART="lib/core/trust/trust_profile.dart"

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

# Non-Apple builds must not resolve or package the Apple-only shader dependency.
if grep -qE '^  liquid_glass_widgets:' pubspec.yaml; then
  fail "默认 pubspec.yaml 不得声明 Apple-only liquid_glass_widgets"
fi
ok "默认依赖图不含 liquid_glass_widgets"

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

# —— 2b. ADR-024 静态前置：哨兵常量两处一致，且没人给 gate 留后门 ——
[[ -f "$TRUST_PROFILE_DART" ]] || fail "缺少 $TRUST_PROFILE_DART（ADR-024 判别器基座）"
if ! grep -qF "'$SIDELOAD_ENTRY_MARKER'" "$TRUST_PROFILE_DART"; then
  fail "$TRUST_PROFILE_DART 的 kSideloadEntryMarker 与本脚本的哨兵不一致（符号断言会失效）"
fi
ok "侧载哨兵常量与 Dart 侧一致（$SIDELOAD_ENTRY_MARKER）"

# 侧载判别器只能是 kSideloadEnabled。若谁把 devSideload() 的守卫改回 kDebugMode/
# kReleaseMode，判别器就又被绑回优化等级——ADR-024 的整个前提失效，且优化版 DEV 包
# 会静默变成「可侧载但被当作 DEPLOY 分发」。
if grep -nE 'if \(!k(Debug|Release|Profile)Mode\)' lib/core/trust/trusted_context.dart >/dev/null; then
  fail "lib/core/trust/trusted_context.dart 的侧载守卫仍绑优化等级（须为 kSideloadEnabled，ADR-024 §2.1）"
fi
ok "侧载守卫挂在信任 profile（非优化等级）"

# —— 3. release 实际构建 + 产物权限（可选跳过）——
if [[ "$STATIC_ONLY" -eq 1 ]]; then
  ok "静态检查通过（--static-only，跳过 APK 构建）"
  exit 0
fi

if [[ -n "${ELECON_RELEASE_GATE_APK:-}" ]]; then
  APK="$ELECON_RELEASE_GATE_APK"
  echo "[release-gate] 使用注入的 APK: $APK"
else
  command -v flutter >/dev/null 2>&1 || fail "未找到 flutter"
  echo "[release-gate] flutter build apk --release --target lib/main.dart …"
  flutter build apk --release --target lib/main.dart
  APK="build/app/outputs/flutter-apk/app-release.apk"
fi
[[ -f "$APK" ]] || fail "未产出 $APK"
ok "产出 release APK: $APK"

# 不使用 grep -q：在 pipefail 下提前退出会让 unzip 收到 SIGPIPE，并把真实命中误判为未命中。
if unzip -l "$APK" | grep -E 'liquid_glass_widgets|liquid_glass_.*\.frag' >/dev/null; then
  fail "release APK 仍包含 Apple-only 液态玻璃资源"
fi
ok "release APK 不含液态玻璃代码资源"

# —— 4. ADR-024 护栏 4：分发产物必须是 DEPLOY（二者并用）——
#
# (a) 符号 grep（结构性）。在**整个 APK 字节流**里找哨兵：Dart AOT 的字符串常量落在
#     libapp.so，snapshot 布局不必假设，直接全包搜最保险。grep -a 按二进制当文本处理。
#     不用 `grep -q`：pipefail 下提前退出会让 unzip 收到 SIGPIPE，把真实命中误判为未命中。
if unzip -p "$APK" '*' 2>/dev/null | grep -aF "$SIDELOAD_ENTRY_MARKER" >/dev/null; then
  fail "release APK 内出现侧载入口哨兵 $SIDELOAD_ENTRY_MARKER —— 该产物含侧载入口，禁止分发（红线 #4 / ADR-024 §2.3 护栏 4a）"
fi
ok "release APK 无侧载入口符号（护栏 4a）"

# (b) 构建元数据标记。缺失同样是失败：没有标记就无从证明构建按 DEPLOY 走
#     （fail-closed；不得因「老产物没有这个文件」而放行）。
PROFILE_MARKER="$(unzip -p "$APK" assets/elecon_build_profile.txt 2>/dev/null | head -1 | tr -d '\r' || true)"
if [[ -z "$PROFILE_MARKER" ]]; then
  fail "release APK 内缺少 assets/elecon_build_profile.txt —— 无法证明构建 profile（护栏 4b fail-closed）"
fi
if [[ "$PROFILE_MARKER" != "DEPLOY" ]]; then
  fail "release APK 的构建 profile 标记为 '$PROFILE_MARKER'，须为 DEPLOY（护栏 4b）"
fi
ok "release APK 构建元数据标记为 DEPLOY（护栏 4b）"

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
