#!/usr/bin/env bash
# 用华为 hap-sign-tool 给未签名 hap 加调试签名，产出可上传云调试的 .hap。
#
# 用法:  tools/ohos/sign-hap.sh <unsigned.hap> [<signed.hap>]
#   不给 <signed.hap> 时，默认把 -unsigned.hap 改名为 -signed.hap。
#
# 签名材料路径从 tools/ohos/sign.env 读（gitignored，见 sign.env.example）。
# 密码经 SIGN_PWD_FILE 文件读取，绝不写进脚本/仓库/日志（输出做 redaction）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$HERE/sign.env" ]; then
  echo "✗ 缺 tools/ohos/sign.env —— 复制 sign.env.example 填写后重试。" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$HERE/sign.env"

: "${OHOS_CLI_HOME:=/opt/ohos_cli_tools}"
JAR="$OHOS_CLI_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
[ -f "$JAR" ] || { echo "✗ 找不到 hap-sign-tool.jar：$JAR（检查 OHOS_CLI_HOME）" >&2; exit 1; }

IN="${1:?用法: sign-hap.sh <unsigned.hap> [signed.hap]}"
[ -f "$IN" ] || { echo "✗ 未签名 hap 不存在：$IN" >&2; exit 1; }
if [ "${2:-}" ]; then OUT="$2"; else
  case "$IN" in
    *-unsigned.hap) OUT="${IN%-unsigned.hap}-signed.hap" ;;
    *)              OUT="${IN%.hap}-signed.hap" ;;
  esac
fi

for v in SIGN_KEYSTORE SIGN_KEY_ALIAS SIGN_APP_CERT SIGN_PROFILE SIGN_PWD_FILE; do
  [ "${!v:-}" ] || { echo "✗ sign.env 缺变量 $v" >&2; exit 1; }
  case "$v" in SIGN_KEY_ALIAS) ;; *) [ -f "${!v}" ] || { echo "✗ $v 指向的文件不存在：${!v}" >&2; exit 1; };; esac
done

PW="$(tr -d '\r\n' < "$SIGN_PWD_FILE")"

java -jar "$JAR" sign-app \
  -keyAlias "$SIGN_KEY_ALIAS" -signAlg "${SIGN_ALG:-SHA256withECDSA}" -mode localSign \
  -appCertFile "$SIGN_APP_CERT" -profileFile "$SIGN_PROFILE" \
  -inFile "$IN" -keystoreFile "$SIGN_KEYSTORE" -outFile "$OUT" \
  -keyPwd "$PW" -keystorePwd "$PW" 2>&1 | sed "s/${PW//\//\\/}/******/g"

echo "✓ signed -> $OUT"
