#!/usr/bin/env bash
# check_release_gate.sh 的**负例**测试：构造几个应当被拒的假 APK，断言 gate 确实拒绝
# 并给出正确原因。
#
# 为什么每条护栏都要有负例：ADR-024 §2.3 把「提交的产物无侧载入口」从 kReleaseMode
# 白送的自动事实，改成了本脚本的机械断言。一条**永远为真**的断言（比如哨兵拼错、
# grep 管道被 SIGPIPE 提前掐断）与没有断言等价，且更危险——它看起来是绿的。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SIDELOAD_ENTRY_MARKER="ELECON_SIDELOAD_ENTRY_A7F3"

# 断言：用 $1 这个 APK 跑 gate 必须失败，且输出含 $2。
expect_reject() {
  local apk="$1" want="$2" label="$3" output
  if output="$(
    cd "$ROOT"
    ELECON_RELEASE_GATE_APK="$apk" bash tool/check_release_gate.sh 2>&1
  )"; then
    echo "[gate-test] ✗ $label：应被拒却放行了" >&2
    exit 1
  fi
  if [[ "$output" != *"$want"* ]]; then
    echo "[gate-test] ✗ $label：拒绝原因不正确" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "[gate-test] ✓ $label"
}

# 让 APK 体积过关（gate 在无 aapt 时会检查体积下限），避免用例因体积而非目标原因被拒。
# 必须用**不可压缩**的随机字节：一大片 'x' 会被 zip 压到几 KB，体积门照样不过。
pad_payload() {
  head -c 1500000 /dev/urandom >"$1/padding.bin"
}

# —— 1. Apple-only 液态玻璃资源（既有护栏）——
mkdir -p "$TMP/glass/flutter_assets/packages/liquid_glass_widgets/shaders"
touch "$TMP/glass/flutter_assets/packages/liquid_glass_widgets/shaders/liquid_glass_test.frag"
pad_payload "$TMP/glass"
(cd "$TMP/glass" && zip -qr "$TMP/contains-liquid-glass.apk" .)
expect_reject "$TMP/contains-liquid-glass.apk" \
  "release APK 仍包含 Apple-only 液态玻璃资源" \
  "含 Apple-only shader 的 APK 被拒"

# —— 2. ADR-024 护栏 4a：产物内仍有侧载入口哨兵 ——
mkdir -p "$TMP/sideload/lib/arm64-v8a" "$TMP/sideload/assets"
printf 'DEPLOY\nELECON_TRUST_PROFILE=\n' >"$TMP/sideload/assets/elecon_build_profile.txt"
# 模拟 AOT 产物里残留的字符串常量：即便元数据标记撒谎说 DEPLOY，符号也要能抓住。
printf 'some other bytes %s more bytes' "$SIDELOAD_ENTRY_MARKER" \
  >"$TMP/sideload/lib/arm64-v8a/libapp.so"
pad_payload "$TMP/sideload"
(cd "$TMP/sideload" && zip -qr "$TMP/contains-sideload-symbol.apk" .)
expect_reject "$TMP/contains-sideload-symbol.apk" \
  "该产物含侧载入口，禁止分发" \
  "含侧载入口符号的 APK 被拒（护栏 4a 不被伪造的元数据糊弄）"

# —— 3. ADR-024 护栏 4b：元数据标记不是 DEPLOY ——
mkdir -p "$TMP/devlabel/assets"
printf 'DEV-SIDELOAD\nELECON_TRUST_PROFILE=dev-sideload\n' \
  >"$TMP/devlabel/assets/elecon_build_profile.txt"
pad_payload "$TMP/devlabel"
(cd "$TMP/devlabel" && zip -qr "$TMP/dev-labelled.apk" .)
expect_reject "$TMP/dev-labelled.apk" \
  "须为 DEPLOY（护栏 4b）" \
  "标记为 DEV-SIDELOAD 的 APK 被拒（护栏 4b）"

# —— 4. ADR-024 护栏 4b fail-closed：完全没有标记文件 ——
mkdir -p "$TMP/nomarker"
pad_payload "$TMP/nomarker"
(cd "$TMP/nomarker" && zip -qr "$TMP/no-marker.apk" .)
expect_reject "$TMP/no-marker.apk" \
  "缺少 assets/elecon_build_profile.txt" \
  "无构建标记的 APK 被拒（fail-closed，不因「老产物没有」而放行）"

# —— 5. 正例：干净的 DEPLOY 产物必须放行 ——
# 没有这条，上面四条负例可能只是「gate 拒绝一切」，断言等于没写。
mkdir -p "$TMP/clean/assets"
printf 'DEPLOY\nELECON_TRUST_PROFILE=\n' >"$TMP/clean/assets/elecon_build_profile.txt"
pad_payload "$TMP/clean"
(cd "$TMP/clean" && zip -qr "$TMP/clean-deploy.apk" .)
if ! output="$(
  cd "$ROOT"
  ELECON_RELEASE_GATE_APK="$TMP/clean-deploy.apk" bash tool/check_release_gate.sh 2>&1
)"; then
  echo "[gate-test] ✗ 干净 DEPLOY 产物被误拒：" >&2
  echo "$output" >&2
  exit 1
fi
echo "[gate-test] ✓ 干净 DEPLOY 产物放行（证明上面的拒绝是有判别力的）"

echo "release gate 用例全部通过（负例 4 + 正例 1）"
