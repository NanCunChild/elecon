#!/bin/sh
set -eu

ROOT="${PUBLIC_DIST_DIR:-/srv/dist}"
MAX_BUNDLE_BYTES=$((512 * 1024))

if [ ! -d "$ROOT/bundles" ]; then
  echo "缺少 bundle 目录：$ROOT/bundles" >&2
  exit 1
fi

for path in "$ROOT"/bundles/*; do
  [ -e "$path" ] || continue
  if [ ! -f "$path" ]; then
    echo "bundle 路径不是普通文件：$path" >&2
    exit 1
  fi
  name="${path##*/}"
  if ! printf '%s\n' "$name" | grep -Eq '^[0-9a-f]{64}\.json\.gz$'; then
    echo "非法 bundle 文件名：$name" >&2
    exit 1
  fi
  size="$(wc -c < "$path" | tr -d ' ')"
  if [ "$size" -gt "$MAX_BUNDLE_BYTES" ]; then
    echo "bundle 超过 ${MAX_BUNDLE_BYTES} bytes：$name ($size)" >&2
    exit 1
  fi
done

echo "public dist bundle 校验通过"
if [ "${1:-}" = "--check-only" ]; then
  exit 0
fi
exec /docker-entrypoint.sh "$@"
