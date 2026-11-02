# client/ — Flutter 客户端

当前架构见[入口](../docs/architecture.md)。独立页面、查询状态复用与增强包绑定见[接口审计](../docs/reference/interface_evolution.md)及[ADR-042 提案](../docs/adr/adr_042_providers_pages_enhancements.md)；这些抽象尚未实现。

## 结构

```
lib/
  main.dart            入口
  core/
    scripts/              ADR-034 受信源码、安装授权、HTTP/IP 与浏览器桥接
    adapter_runtime.dart  V1 兼容运行时（declarative/imperative requestGraph，后台 isolate）
  ui/                  固定原生页面与卡片（消费标准业务数据，不接受 Widget tree）
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
fvm flutter run  # Android / 非 Apple 桌面
bash tool/with_apple_pubspec.sh fvm flutter run --target lib/main_apple.dart  # iOS / macOS
```

## Android APK 构建

在已有 Flutter、Android SDK/NDK 与 Rust（rustup/Cargo）的环境中，先安装默认 APK 包含的三个 Rust 目标：

```bash
rustup target add armv7-linux-androideabi aarch64-linux-android x86_64-linux-android
cd client
fvm flutter build apk
```

Hermes 原生库随应用构建。Gradle 将本次选定的 NDK 目录传给构建脚本，与 `flutter.ndkVersion` 一致；不再从已安装的多个 NDK 中自行选择最新版本。缺少 Rust 目标时会在开始编译前列出完整安装命令，构建过程不自动下载安装工具链。单独构建原生库时需传 `--ndk-dir /path/to/ndk`（或显式设置 `ANDROID_NDK_HOME`）。CI 与 release 工作流也安装各自需要的 Rust 目标。

仓库跟踪由 Gradle 9.1.0 `wrapper` 任务生成的脚本和 JAR（Gradle，Apache-2.0），JAR 已与官方 SHA256 核对，分发 ZIP 的 SHA256 固定在 wrapper properties；不再依赖 Flutter 临时生成旧 wrapper。Gradle launcher 已显式允许 JNI native access，以适配 Android Studio 的 JDK 25，消除 `System::load` restricted-method 警告；该参数也适用于 CI 的 JDK 17。只给 daemon 设置 `org.gradle.jvmargs` 无法覆盖 launcher。依据：[Gradle 9.1 Java 25 支持](https://docs.gradle.org/9.1.0/release-notes.html)、[JDK 25 native access](https://docs.oracle.com/en/java/javase/25/migrate/migrating-jdk-8-later-jdk-releases.html)。

`pub get` 的“有较新版本可用”提示不代表构建失败，无须为清除提示更新已固定的核心依赖。本地 release 没有发布密钥时仍使用调试签名；Git 提交不签名与 APK 的安装签名是两回事。

## Flutter 版本策略

- Android / iOS 主线跟进官方 Flutter stable；当前基线为 Flutter 3.44.1 / Dart 3.12.1。
- OHOS 使用 OpenHarmony-SIG Flutter-OHOS fork（当前 3.27.5-ohos-1.0.4 / Dart 3.6.2），作为挂起旁路线等待上游更新或官方主线支持。
- 主线新增 Dart 语法、依赖版本、`pubspec.lock` 解析结果以 Android / iOS stable 为准；不为 OHOS fork 牺牲主线升级节奏。
- OHOS 恢复打包前再核对 fork 是否跟进。若主线已使用 OHOS fork 不支持的语法或依赖，按兼容债务处理，见 `docs/probes/probe_001_smoke_plan.md` §4.1。

## 测试（V1 双跑一致性与新脚本回归）

V1 adapter 在客户端用 QuickJS（`flutter_qjs_next`）执行，服务端使用 QuickJS-wasm。新源码脚本只在客户端执行，其格式、凭据、HTTP/DOM、身份与安装版本回归位于 `test/scripts/`，不要求服务端双跑或旧 Masker。

V1 两端的绑定、
版本和编译配置可能不同，只对共享 golden/canary 覆盖的已使用语义承诺一致（ADR-008 §3.2）。
`test/legacy/dual_run_test.dart` 用同一份 declarative 夹具验证客户端产出 == golden，服务端侧由
`server/src/runtime/sandbox.smoke.ts` 验证同一 golden。

`flutter_qjs_next` 是经典 FFI 插件，纯 `flutter test` 不会构建其原生库。先一次性构建：

```bash
fvm flutter pub get
tool/build_qjs_test_lib.sh        # 输出 FLUTTER_QJS_NEXT_LIBRARY 路径（仅 Linux）
FLUTTER_QJS_NEXT_LIBRARY=/path/to/libflutter_qjs_next_plugin.so fvm flutter test test/legacy/dual_run_test.dart
```

> **依赖说明**：`flutter_qjs_next` 是迁移后的 QuickJS 绑定（非 flutter_js——后者 iOS 用
> JavaScriptCore，会扩大跨端语义差异与测试矩阵）。它使用更新 QuickJS、`ffi` 2.x，并移除了旧
> `flutter_qjs` 的 Android Kotlin Gradle Plugin 阻塞。

### Linux QuickJS 测试库记录

`flutter test` 运行在 host VM 上，不会自动编译 FFI 插件的 Linux `.so`。当前开发环境
（Flutter 3.44.1 / Dart 3.12.1，Linux x64）的标准流程是：

```bash
cd client
fvm flutter pub get
bash tool/flutter_test.sh fvm flutter test
```

包装器会在缺少原生库时调用 `build_qjs_test_lib.sh`：从 `.dart_tool/package_config.json`
定位 `flutter_qjs_next`，复制到临时构建目录，创建/构建一个最小 Linux example，并自动向
测试进程注入 `FLUTTER_QJS_NEXT_LIBRARY`。本地与 CI 使用同一入口，无需手工复制库路径。

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
- 凭据仍由宿主保护；ADR-034 受信源码可直接访问当前授权学校身份的值，V1 adapter 仍遵守凭据不可见边界

## 受信学校脚本（Alpha 0.2）

首次选校页或设置页打开“学校脚本”，导入/粘贴源码包并确认后即可使用。无需修改选校硬编码，也无需官方签名本地脚本。使用、版本更新、HTTP/DOM 模板和平台限制见 [开发文档](../docs/reference/trusted_scripts.md)。旧 official bundle 路径仍验证原签名。

新模板采用 SDK 2（[ADR-035](../docs/adr/adr_035_script_credential_identity.md)）：凭据默认按学校、脚本命名空间、键保存，并可显式共享。SDK 1 预览语义继续兼容。包格式仍为 `elecon-script/1`，脚本自身 version 独立递增。

西电实际脚本见 [school-scripts/xidian](../school-scripts/xidian/README.md)。客户端本地版本 0.2.1+3 修复锁定 QuickJS 绑定的长字符串跨桥问题。`test/scripts/xidian_script_test.dart` 会通过 Node 工作区构建真实源码包再运行；首次全量测试前，在仓库根执行 `npm ci`。CI 的 client job 已安装该前置，测试仍不请求学校。
