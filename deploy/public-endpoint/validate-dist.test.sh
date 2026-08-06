#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bundles"

VALID="$(printf 'a%.0s' {1..64}).json.gz"
touch "$TMP/bundles/$VALID"
PUBLIC_DIST_DIR="$TMP" sh "$ROOT/validate-dist.sh" --check-only

touch "$TMP/bundles/not-a-digest.json.gz"
if PUBLIC_DIST_DIR="$TMP" sh "$ROOT/validate-dist.sh" --check-only >/dev/null 2>&1; then
  echo "非法 bundle 文件名被错误放行" >&2
  exit 1
fi
rm "$TMP/bundles/not-a-digest.json.gz"

truncate -s $((512 * 1024 + 1)) "$TMP/bundles/$VALID"
if PUBLIC_DIST_DIR="$TMP" sh "$ROOT/validate-dist.sh" --check-only >/dev/null 2>&1; then
  echo "超限 bundle 被错误放行" >&2
  exit 1
fi

echo "public dist 校验负例通过"
