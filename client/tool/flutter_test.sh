#!/usr/bin/env bash
# Runs Flutter tests with the Linux flutter_qjs_next native library available.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
  set -- flutter test
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  LIB="$ROOT/.dart_tool/flutter_qjs_next_test_build/example/build/linux/x64/debug/bundle/lib/libflutter_qjs_next_plugin.so"
  if [[ ! -f "$LIB" ]]; then
    bash "$ROOT/tool/build_qjs_test_lib.sh"
  fi
  [[ -f "$LIB" ]] || { echo "缺少 flutter_qjs_next Linux 测试库：$LIB" >&2; exit 1; }
  export FLUTTER_QJS_NEXT_LIBRARY="$LIB"
fi

cd "$ROOT"
exec "$@"
