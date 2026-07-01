#!/usr/bin/env bash
# 一步出 signed debug hap：flutter build hap --debug（ohos fork）→ 后置签名。
#   用法： tools/ohos/build-hap.sh
#   产物： client/ohos/entry/build/default/outputs/default/entry-default-signed.hap
#
# Flutter 版本分叉：主线锁官方 3.44.1，OHOS 只能用 ohos fork（见 client/ohos/README §0）。
# 本脚本经 fvm spawn 固定用 ohos fork，不污染主线默认 SDK。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OHOS_FLUTTER_REF="${OHOS_FLUTTER_REF:-ohos/br_3.27.4-ohos-1.0.4}"
OUT_DIR="$REPO_ROOT/client/ohos/entry/build/default/outputs/default"

# shellcheck disable=SC1091
source "$REPO_ROOT/tools/ohos/env.sh"

echo "[build] flutter build hap --debug（$OHOS_FLUTTER_REF）…"
( cd "$REPO_ROOT/client" && fvm spawn "$OHOS_FLUTTER_REF" build hap --debug )

UNSIGNED="$OUT_DIR/entry-default-unsigned.hap"
[ -f "$UNSIGNED" ] || { echo "[build] ✗ 未产出 unsigned hap: $UNSIGNED" >&2; exit 1; }

echo "[build] 后置签名…"
"$REPO_ROOT/tools/ohos/sign-hap.sh" "$UNSIGNED"
