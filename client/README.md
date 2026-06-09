# client/ — Flutter 客户端

## 结构

```
lib/
  main.dart            入口
  core/
    adapter_runtime.dart  QuickJS adapter 运行时（parser 模式，后台 isolate）
  ui/                  UI 层（数据驱动 / SDUI，只认标准 schema）
assets/                静态资源
test/
  dual_run_test.dart   双跑一致性（客户端半边）
tool/
  build_qjs_test_lib.sh  构建 flutter_qjs FFI 测试库
```

## 运行

```bash
cd client
fvm flutter pub get
fvm flutter run
```

## 测试（双跑一致性）

adapter 在客户端用 QuickJS（`flutter_qjs`）执行，与服务端 QuickJS-wasm 是同一引擎、
零语义漂移（ADR-001 §8、ADR-005）。`test/dual_run_test.dart` 用同一份 parser 夹具验证
客户端产出 == golden（服务端侧由 `server/src/runtime/sandbox.smoke.ts` 证），传递得两端一致。

`flutter_qjs` 是经典 FFI 插件，纯 `flutter test` 不会构建其原生库。先一次性构建：

```bash
fvm flutter pub get
tool/build_qjs_test_lib.sh        # → test/build/libffiquickjs.so（仅 Linux）
fvm flutter test test/dual_run_test.dart
```

> **依赖说明**：`flutter_qjs` 选 ekibun 全平台 QuickJS 版（非 flutter_js——后者 iOS 用
> JavaScriptCore，会破坏“同一引擎零漂移”）。0.3.7 已停更且在 Dart 3.12 编不过，故
> `pubspec.yaml` 用 `dependency_overrides` 指向打了一行兼容补丁的 fork。详见客户端运行时 ADR。

## 原则

- adapter 在后台 isolate 执行，不在 UI 线程同步阻塞
- UI 只认标准 schema，与学校无关
- 凭证永不离开核心
