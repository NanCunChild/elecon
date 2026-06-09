#!/usr/bin/env bash
#
# 构建 flutter_qjs 的 FFI 原生库到 client/test/build/libffiquickjs.so。
#
# 为什么需要它：flutter_qjs 是经典插件，原生库由各平台构建系统编译；纯
# `flutter test`（host VM）不会构建它。但其 ffi.dart 在 FLUTTER_TEST=true 时
# 从相对路径 `test/build/libffiquickjs.so` 加载——于是我们用包自带的 QuickJS
# 源码（cxx/）经 CMake 预构建该库，即可在无显示器/无 xvfb 下跑 `flutter test`。
#
# 前置：先 `fvm flutter pub get`（生成 .dart_tool/package_config.json）。
# 仅 Linux（其余平台的 desktop 测试基建按需补）。
set -euo pipefail
cd "$(dirname "$0")/.." # → client/

case "$(uname -s)" in
  Linux) ;;
  Darwin)
    echo "macOS 暂未支持：需把目标产物改为 test/build/libffiquickjs.dylib（见 flutter_qjs ffi.dart 的 FLUTTER_TEST 分支），并用 Xcode/clang 构建。" >&2
    exit 1 ;;
  *)
    echo "本脚本目前仅支持 Linux desktop；其他平台请按 flutter_qjs 的 cxx/ 源码自行扩展构建。" >&2
    exit 1 ;;
esac

if [ ! -f .dart_tool/package_config.json ]; then
  echo "缺少 .dart_tool/package_config.json，请先运行: fvm flutter pub get" >&2
  exit 1
fi

# 从 package_config 动态定位 flutter_qjs（兼容 hosted/git/path 依赖）。
PKG=$(python3 -c "import json; d=json.load(open('.dart_tool/package_config.json')); print(next(p['rootUri'] for p in d['packages'] if p['name']=='flutter_qjs'))")
PKG=${PKG#file://}

# modern GCC（14+）把 int-conversion 等老式 C 写法默认当 error；
# 2021 版 QuickJS 需把它们降级为警告。仅作用于 C。
C_FLAGS="-Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-int-conversion"

cmake -S "${PKG}test" -B test/build -G Ninja -DCMAKE_C_FLAGS="$C_FLAGS"
cmake --build test/build
echo "built: client/test/build/libffiquickjs.so"
