# client/ — Flutter 客户端

## 结构

```
lib/
  main.dart            入口
  core/
    adapter_runtime.dart  QuickJS adapter 运行时（declarative/imperative requestGraph，后台 isolate）
  ui/                  UI 层（数据驱动 / SDUI，只认标准 schema）
assets/                静态资源
test/
  utils/
    test_utils.dart    共享测试工具（repoRoot / readGolden / FakeResolver / FakeTransport / viewFromJson）
  dual_run_test.dart   双跑一致性（客户端半边）
  broker_*_test.dart   broker 组件冒烟测试（与 server 共用 contract/golden/ 向量）
tool/
  build_qjs_test_lib.sh  构建 flutter_qjs_next FFI 测试库
```

## 运行

```bash
cd client
fvm flutter pub get
fvm flutter run
```

## Flutter 版本策略

- Android / iOS 主线跟进官方 Flutter stable；当前基线为 Flutter 3.44.1 / Dart 3.12.1。
- OHOS 使用 OpenHarmony-SIG Flutter-OHOS fork（当前 3.27.5-ohos-1.0.4 / Dart 3.6.2），作为挂起旁路线等待上游更新或官方主线支持。
- 主线新增 Dart 语法、依赖版本、`pubspec.lock` 解析结果以 Android / iOS stable 为准；不为 OHOS fork 牺牲主线升级节奏。
- OHOS 恢复打包前再核对 fork 是否跟进。若主线已使用 OHOS fork 不支持的语法或依赖，按兼容债务处理，见 `docs/probes/probe_001_smoke_plan.md` §4.1。

## 测试（双跑一致性）

adapter 在客户端用 QuickJS（`flutter_qjs_next`）执行，与服务端 QuickJS-wasm 是同一引擎、
零语义漂移（ADR-001 §8、ADR-005）。`test/dual_run_test.dart` 用同一份 declarative 夹具验证
客户端产出 == golden（服务端侧由 `server/src/runtime/sandbox.smoke.ts` 证），传递得两端一致。

`flutter_qjs_next` 是经典 FFI 插件，纯 `flutter test` 不会构建其原生库。先一次性构建：

```bash
fvm flutter pub get
tool/build_qjs_test_lib.sh        # 输出 FLUTTER_QJS_NEXT_LIBRARY 路径（仅 Linux）
FLUTTER_QJS_NEXT_LIBRARY=/path/to/libflutter_qjs_next_plugin.so fvm flutter test test/dual_run_test.dart
```

> **依赖说明**：`flutter_qjs_next` 是迁移后的 QuickJS 绑定（非 flutter_js——后者 iOS 用
> JavaScriptCore，会破坏“同一引擎零漂移”）。它使用更新 QuickJS、`ffi` 2.x，并移除了旧
> `flutter_qjs` 的 Android Kotlin Gradle Plugin 阻塞。

### Linux QuickJS 测试库记录

`flutter test` 运行在 host VM 上，不会自动编译 FFI 插件的 Linux `.so`。当前开发环境
（Flutter 3.44.1 / Dart 3.12.1，Linux x64）的标准流程是：

```bash
cd client
fvm flutter pub get
tool/build_qjs_test_lib.sh
FLUTTER_QJS_NEXT_LIBRARY="$PWD/.dart_tool/flutter_qjs_next_test_build/example/build/linux/x64/debug/bundle/lib/libflutter_qjs_next_plugin.so" \
  fvm flutter test
```

脚本会从 `.dart_tool/package_config.json` 定位 `flutter_qjs_next`，复制到临时构建目录，
创建/构建一个最小 Linux example，并输出 `libflutter_qjs_next_plugin.so` 的绝对路径。CI
通过 `GITHUB_ENV` 自动注入该环境变量；本地 shell 需要按上面的方式显式传入。

更换开发环境、Flutter 版本、架构或 `flutter_qjs_next` 版本时，需检查：

- 安装 Linux Flutter desktop 依赖：`cmake`、`ninja-build`、`pkg-config`、`libgtk-3-dev` 及 C/C++ 编译器。
- 重新执行 `fvm flutter pub get` 和 `tool/build_qjs_test_lib.sh`，不要复用旧 `.dart_tool/flutter_qjs_next_test_build`。
- 确认 `.so` 架构与测试运行架构一致，并将 `FLUTTER_QJS_NEXT_LIBRARY` 指向新路径。
- 若升级 Flutter、Dart、插件或切换 hosted/git/path 依赖，重新核对 package 的 Linux CMake/Rust/FFI 构建接口。
- 若迁移到 macOS/Windows，扩展脚本的 OS 分支，并分别构建 `.dylib`/`.dll`；当前脚本只支持 Linux。
- 不提交 `.so`、`build/`、`.dart_tool/flutter_qjs_next_test_build/` 等本机构建产物。

## 性能分析（MVP）

性能追踪默认在编译期关闭。开发或 profile 构建时显式开启：

```bash
fvm flutter run --dart-define=ELECON_PERF=true
fvm flutter build apk --profile --dart-define=ELECON_PERF=true
```

开启后输出 `[perf]` JSON 时间线，覆盖启动、存储准备、路由切换、WebView 创建与加载、
cookie 收割和持久化完成等阶段，同时输出帧总数、超过 16.67ms 的慢帧数和最大帧耗时。
输出不包含 URL、cookie、请求头、响应体或凭证值。
未提供该参数时 `performanceTracingEnabled` 为编译期常量 `false`，埋点调用为空操作，
发布构建不会保留性能追踪行为。

## 原则

- adapter 在后台 isolate 执行，不在 UI 线程同步阻塞
- UI 只认标准 schema，与学校无关
- 凭证永不离开核心
