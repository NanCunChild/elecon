#!/usr/bin/env bash
# 一步出可上传华为云调试的【已签名 debug hap】：flutter build hap → hap-sign-tool 签名。
#
# 用法:  tools/ohos/build-hap.sh
# 前置:  tools/ohos/env.sh（OHOS 环境）+ tools/ohos/sign.env（签名材料）已就绪；
#        Flutter-OHOS fork 已 `config --ohos-sdk`（见 tools/ohos/README.md）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tools/ohos/env.sh"
OHOS_VER="${OHOS_FLUTTER_VERSION:-ohos/br_3.27.4-ohos-1.0.4}"
UNSIGNED="$ROOT/client/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap"

echo "== flutter build hap --debug =="
# 注：signingConfigs 为空时 flutter-ohos 包装器会在末尾报"请配置签名"并以非零退出，
# 但 unsigned hap 此前已由 hvigor 产出 —— 我们走 CLI 后置签名，故忽略该退出码、改判产物存在性。
( cd "$ROOT/client" && fvm spawn "$OHOS_VER" build hap --debug ) || true
[ -f "$UNSIGNED" ] || { echo "✗ 未生成 unsigned hap，构建真失败。" >&2; exit 1; }

echo "== 签名 =="
"$ROOT/tools/ohos/sign-hap.sh" "$UNSIGNED"
