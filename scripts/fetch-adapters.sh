#!/usr/bin/env bash
# 按需拉取公开仓 elecon-adapters 的 adapters/（ADR-018 §2.11.1），取代 git 子模块。
#
# 从 adapters.pin 读钉死的 ref，浅克隆 ncc-devlab/elecon-adapters 到一个 gitignored 缓存目录，
# 供消费侧接缝（smoke-utils.ts / test_utils.dart 的 ELECON_ADAPTERS_REPO）使用。
# 方向严格单向 core←A，只取 adapters/；绝不回写 A。
#
#   用法： bash scripts/fetch-adapters.sh [目标目录]
#   缺省目标： <repo>/.adapters-cache/elecon-adapters
#   在 GitHub Actions 下自动把 ELECON_ADAPTERS_REPO 写入 $GITHUB_ENV，后续 step 即可用。
set -euo pipefail

REPO_URL="${ELECON_ADAPTERS_URL:-https://github.com/ncc-devlab/elecon-adapters.git}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIN_FILE="$CORE_ROOT/adapters.pin"
TARGET="${1:-$CORE_ROOT/.adapters-cache/elecon-adapters}"

if [[ ! -f "$PIN_FILE" ]]; then
  echo "✗ 缺 pin 文件：$PIN_FILE" >&2
  exit 1
fi

# 第一行非注释、非空 = ref
REF="$(grep -vE '^\s*(#|$)' "$PIN_FILE" | head -n1 | tr -d '[:space:]')"
if [[ -z "$REF" ]]; then
  echo "✗ adapters.pin 未含有效 ref" >&2
  exit 1
fi

echo "拉取 $REPO_URL @ $REF → $TARGET"
rm -rf "$TARGET"
mkdir -p "$TARGET"
git -C "$TARGET" init -q
git -C "$TARGET" remote add origin "$REPO_URL"
# 浅取指定 ref（GitHub 允许 fetch 任意可达 SHA）
git -C "$TARGET" fetch -q --depth 1 origin "$REF"
git -C "$TARGET" checkout -q FETCH_HEAD

if [[ ! -d "$TARGET/adapters" ]]; then
  echo "✗ 拉取结果缺 adapters/，不像 elecon-adapters：$TARGET" >&2
  exit 1
fi

echo "✓ elecon-adapters @ $REF 就绪（adapters/ 可用）"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "ELECON_ADAPTERS_REPO=$TARGET" >>"$GITHUB_ENV"
  echo "  已导出 ELECON_ADAPTERS_REPO=$TARGET 至 \$GITHUB_ENV"
fi
