#!/usr/bin/env bash
# 一步出 signed hap：flutter build hap（ohos fork）→ 后置签名（按 build mode 自选签名材料）。
#   用法：
#     tools/ohos/build-hap.sh                                    # 默认 debug
#     tools/ohos/build-hap.sh --release                          # release
#     tools/ohos/build-hap.sh --debug --dart-define=OHOS_PROBE=true   # 透传其余 flutter 参数
#   产物： client/ohos/entry/build/default/outputs/default/entry-default-<mode>-signed.hap
#
# Flutter 版本分叉：主线锁官方 3.44.1，OHOS 只能用 ohos fork（见 client/ohos/README §0）。
# 本脚本经 fvm spawn 固定用 ohos fork，不污染主线默认 SDK。
# OHOS 专用依赖通过 client/pubspec.ohos.yaml 临时覆盖，不写入主线 pubspec/lock。
#
# 签名材料按 mode 自助选择（见 tools/ohos/README「debug/release 分签」）：
#   debug   → tools/ohos/sign.debug.env  （缺省回退 legacy sign.env）
#   release → tools/ohos/sign.release.env（缺省回退 legacy sign.env）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OHOS_FLUTTER_REF="${OHOS_FLUTTER_REF:-ohos/br_3.27.4-ohos-1.0.4}"
OUT_DIR="$REPO_ROOT/client/ohos/entry/build/default/outputs/default"
CLIENT_DIR="$REPO_ROOT/client"
MAIN_PUBSPEC="$CLIENT_DIR/pubspec.yaml"
OHOS_PUBSPEC="$CLIENT_DIR/pubspec.ohos.yaml"
LOCKFILE="$CLIENT_DIR/pubspec.lock"

# —— 解析 build mode（--debug/--release，默认 debug），其余参数原样透传 flutter ——
MODE=debug
PASSTHRU=()
HAS_TARGET=0
WANTS_PROBE=0
for arg in "$@"; do
  case "$arg" in
    --debug)   MODE=debug ;;
    --release) MODE=release ;;
    --target|--target=*) HAS_TARGET=1; PASSTHRU+=("$arg") ;;
    --dart-define=OHOS_PROBE=true) WANTS_PROBE=1; PASSTHRU+=("$arg") ;;
    *)         PASSTHRU+=("$arg") ;;
  esac
done

if [ "$WANTS_PROBE" -eq 1 ] && [ "$HAS_TARGET" -eq 0 ]; then
  PASSTHRU+=("--target=ohos_probe/main.dart")
fi

[ -f "$OHOS_PUBSPEC" ] || { echo "[build] ✗ 缺少 OHOS pubspec: $OHOS_PUBSPEC" >&2; exit 1; }

PUBSPEC_BAK="$(mktemp)"
LOCK_BAK="$(mktemp)"
LOCK_EXISTED=0
cp "$MAIN_PUBSPEC" "$PUBSPEC_BAK"
if [ -f "$LOCKFILE" ]; then
  cp "$LOCKFILE" "$LOCK_BAK"
  LOCK_EXISTED=1
fi

restore_pubspec() {
  cp "$PUBSPEC_BAK" "$MAIN_PUBSPEC"
  if [ "$LOCK_EXISTED" -eq 1 ]; then
    cp "$LOCK_BAK" "$LOCKFILE"
  else
    rm -f "$LOCKFILE"
  fi
  rm -f "$PUBSPEC_BAK" "$LOCK_BAK"
}
trap restore_pubspec EXIT

cp "$OHOS_PUBSPEC" "$MAIN_PUBSPEC"

# shellcheck disable=SC1091
source "$REPO_ROOT/tools/ohos/env.sh"

# 先删旧 unsigned，令后续「是否产出」判定不被上一次构建的陈旧产物污染。
UNSIGNED="$OUT_DIR/entry-default-unsigned.hap"
rm -f "$UNSIGNED"

# 注：ohos fork 的 flutter build hap 在无 DevEco 自动签名配置时会返回非零，但仍产出 unsigned hap。
# 故此处容忍其非零退出，改以「是否产出 unsigned」判定成败，随后走脚本自带的本地后置签名。
echo "[build] flutter build hap --$MODE ${PASSTHRU[*]:-}（$OHOS_FLUTTER_REF / pubspec.ohos.yaml）…"
build_rc=0
( cd "$CLIENT_DIR" && fvm spawn "$OHOS_FLUTTER_REF" build hap --"$MODE" "${PASSTHRU[@]}" ) || build_rc=$?

[ -f "$UNSIGNED" ] || { echo "[build] ✗ 未产出 unsigned hap（flutter build hap 退出码 $build_rc）: $UNSIGNED" >&2; exit 1; }
[ "$build_rc" -ne 0 ] && echo "[build] 提示：flutter build hap 退出码 $build_rc（多为缺 DevEco 自动签名配置），已产出 unsigned，转本地后置签名。"

echo "[build] 后置签名（mode=$MODE）…"
"$REPO_ROOT/tools/ohos/sign-hap.sh" "$UNSIGNED" --"$MODE"
