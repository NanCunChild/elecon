#!/usr/bin/env bash
#
# 构建 flutter_qjs_next 的 Linux FFI 原生库，供 client/flutter test 使用。
#
# 为什么需要它：flutter_qjs_next 是经典 FFI 插件，原生库由各平台构建系统编译；
# 纯 `flutter test`（host VM）不会构建它。先构建插件自带 example 的 Linux bundle，
# 再把 FLUTTER_QJS_NEXT_LIBRARY 指向 bundle 内的 libflutter_qjs_next_plugin.so。
#
# 前置：先 `fvm flutter pub get`（生成 .dart_tool/package_config.json）。
# 仅 Linux（其余平台的 desktop 测试基建按需补）。
set -euo pipefail
cd "$(dirname "$0")/.." # → client/

case "$(uname -s)" in
  Linux) ;;
  Darwin)
    echo "macOS 暂未支持：需先补 flutter_qjs_next macOS 测试库构建路径。" >&2
    exit 1 ;;
  *)
    echo "本脚本目前仅支持 Linux desktop；其他平台请按 flutter_qjs_next 的平台构建产物自行扩展。" >&2
    exit 1 ;;
esac

if [ ! -f .dart_tool/package_config.json ]; then
  echo "缺少 .dart_tool/package_config.json，请先运行: fvm flutter pub get" >&2
  exit 1
fi

# 从 package_config 动态定位 flutter_qjs_next（兼容 hosted/git/path 依赖）。
# rootUri 按 package_config 规范是相对 .dart_tool/ 解析的：git/hosted 为绝对 file://（带尾斜杠），
# 但 path 依赖为相对路径（无尾斜杠）。故必须相对 .dart_tool/ 解析成绝对路径，再用 path join，
# 否则 path 依赖会算错（多一层 .. + 缺斜杠 → ${PKG}test 拼成无效路径）。
PKG=$(python3 -c "
import json, os
cfg = '.dart_tool/package_config.json'
d = json.load(open(cfg))
uri = next(p['rootUri'] for p in d['packages'] if p['name'] == 'flutter_qjs_next')
if uri.startswith('file://'):
    uri = uri[len('file://'):]
base = os.path.dirname(os.path.abspath(cfg))  # client/.dart_tool —— rootUri 的解析基准
print(os.path.normpath(os.path.join(base, uri)))
")

BUILD_SRC="$(pwd)/.dart_tool/flutter_qjs_next_test_build"
rm -rf "$BUILD_SRC"
mkdir -p "$BUILD_SRC"
cp -a "$PKG/." "$BUILD_SRC/"

(
  cd "$BUILD_SRC/example"
  flutter build linux --debug
)

LIB="$BUILD_SRC/example/build/linux/x64/debug/bundle/lib/libflutter_qjs_next_plugin.so"
if [ ! -f "$LIB" ]; then
  echo "构建完成但未找到: $LIB" >&2
  exit 1
fi

echo "built: $LIB"

# GitHub Actions 里把库路径导出给后续步骤（flutter test），本地则打印手动运行方式。
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "FLUTTER_QJS_NEXT_LIBRARY=$LIB" >> "$GITHUB_ENV"
else
  echo "run tests with:"
  echo "FLUTTER_QJS_NEXT_LIBRARY=$LIB flutter test"
fi
