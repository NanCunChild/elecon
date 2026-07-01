#!/usr/bin/env bash
# 只对一个已有 unsigned hap 后置签名（不重编）。
#   用法： tools/ohos/sign-hap.sh <path/to/entry-default-unsigned.hap>
#   产物： 同目录 entry-default-signed.hap
#
# 签名材料经 tools/ohos/sign.env（gitignored）注入，绝不入库（红线 #8）。
# HarmonyOS NEXT 要求 debug hap 亦须签名；无 IDE 时走 hap-sign-tool.jar localSign。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${OHOS_CLI_HOME:=/opt/ohos_cli_tools}"

# —— 签名材料 ——（路径/别名/算法都从 sign.env 取，脚本不写死机器相关值）
SIGN_ENV="$REPO_ROOT/tools/ohos/sign.env"
[ -f "$SIGN_ENV" ] || { echo "[sign] ✗ 缺 $SIGN_ENV（从 sign.env.example 复制并填本机路径）" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SIGN_ENV"

UNSIGNED="${1:?用法: sign-hap.sh <unsigned.hap>}"
[ -f "$UNSIGNED" ] || { echo "[sign] ✗ 找不到 unsigned hap: $UNSIGNED" >&2; exit 1; }
SIGNED="$(dirname "$UNSIGNED")/entry-default-signed.hap"

SIGN_TOOL="$OHOS_CLI_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
[ -f "$SIGN_TOOL" ] || { echo "[sign] ✗ 缺 hap-sign-tool.jar: $SIGN_TOOL" >&2; exit 1; }

PWD_VAL="$(cat "$SIGN_PWD_FILE")"

echo "[sign] in : $UNSIGNED"
echo "[sign] out: $SIGNED"
echo "[sign] profile=$SIGN_PROFILE alias=$SIGN_KEY_ALIAS alg=${SIGN_ALG:-SHA256withECDSA}"

java -jar "$SIGN_TOOL" sign-app \
  -mode localSign \
  -keyAlias "$SIGN_KEY_ALIAS" \
  -signAlg "${SIGN_ALG:-SHA256withECDSA}" \
  -appCertFile "$SIGN_APP_CERT" \
  -profileFile "$SIGN_PROFILE" \
  -inFile "$UNSIGNED" \
  -keystoreFile "$SIGN_KEYSTORE" \
  -outFile "$SIGNED" \
  -keyPwd "$PWD_VAL" \
  -keystorePwd "$PWD_VAL" \
  -signCode "1"

echo "[sign] ✓ 签名完成 → $SIGNED"
echo "[sign] 验证："
java -jar "$SIGN_TOOL" verify-app -inFile "$SIGNED" -outCertChain /tmp/ohos_verify_chain.cer -outProfile /tmp/ohos_verify_profile.p7b \
  && echo "[sign] ✓ Verify success"
