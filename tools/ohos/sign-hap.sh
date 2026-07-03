#!/usr/bin/env bash
# 只对一个已有 unsigned hap 后置签名（不重编），按 mode 自选签名材料。
#   用法：
#     tools/ohos/sign-hap.sh <unsigned.hap>            # 默认 debug
#     tools/ohos/sign-hap.sh <unsigned.hap> --release  # release
#   产物： 同目录 entry-default-<mode>-signed.hap
#
# 签名材料经 gitignored env 注入，绝不入库（红线 #8）。按 mode 自助选择：
#   debug   → tools/ohos/sign.debug.env  （缺省回退 legacy sign.env）
#   release → tools/ohos/sign.release.env（缺省回退 legacy sign.env）
# HarmonyOS NEXT 要求 debug hap 亦须签名；无 IDE 时走 hap-sign-tool.jar localSign。
#
# ⚠️ profile 更新只需**重新签名**（本脚本），无需重编：
#    换真机 UDID / 证书续期 / 换 profile —— profile 是签名期嵌入 hap 签名块，不进编译产物，
#    改 sign.<mode>.env 的路径后对已有 unsigned hap 重跑本脚本即可。
#    唯一例外：profile 的 **bundle id 变了** —— bundle id 编进 hap，须先改 AppScope/app.json5
#    的 bundleName 再走 tools/ohos/build-hap.sh 重编，单独重签会 install 失败。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${OHOS_CLI_HOME:=/opt/ohos_cli_tools}"

UNSIGNED="${1:?用法: sign-hap.sh <unsigned.hap> [--debug|--release]}"
case "${2:-}" in
  --release)      MODE=release ;;
  --debug|"")     MODE=debug ;;
  *) echo "[sign] ✗ 未知参数: ${2:-}（第二参数用 --debug|--release）" >&2; exit 1 ;;
esac

# —— 按 mode 自助选择签名材料：sign.<mode>.env 优先，缺省回退 legacy sign.env ——
SIGN_ENV="$REPO_ROOT/tools/ohos/sign.$MODE.env"
[ -f "$SIGN_ENV" ] || SIGN_ENV="$REPO_ROOT/tools/ohos/sign.env"
[ -f "$SIGN_ENV" ] || {
  echo "[sign] ✗ 缺签名材料：tools/ohos/sign.$MODE.env（从 sign.$MODE.env.example 复制并填本机路径）" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$SIGN_ENV"

[ -f "$UNSIGNED" ] || { echo "[sign] ✗ 找不到 unsigned hap: $UNSIGNED" >&2; exit 1; }
SIGNED="$(dirname "$UNSIGNED")/entry-default-$MODE-signed.hap"

SIGN_TOOL="$OHOS_CLI_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
[ -f "$SIGN_TOOL" ] || { echo "[sign] ✗ 缺 hap-sign-tool.jar: $SIGN_TOOL" >&2; exit 1; }

# ⚠️ 残余风险：hap-sign-tool 只接受 -keyPwd/-keystorePwd 命令行参数（无 stdin/密码文件机制），
#    签名运行期间密码经 /proc/<pid>/cmdline 对本机其他进程可见——只在本机非共享环境执行
#    （详见 tools/ohos/README.md「残余风险」节）。
PWD_VAL="$(cat "$SIGN_PWD_FILE")"

echo "[sign] mode=$MODE  env=${SIGN_ENV#"$REPO_ROOT"/}"
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
