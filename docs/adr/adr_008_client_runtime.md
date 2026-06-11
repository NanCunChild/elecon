# ADR-006：客户端 adapter 执行运行时（QuickJS / Flutter）

- **状态**：已接受（Accepted）
- **日期**：2026-06-09
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)、[`adr_001_contract.md`](./adr_001_contract.md)、[`adr_005_runtime.md`](./adr_005_runtime.md)
- **适用范围**：`client/` 客户端对 adapter 的执行栈。与 ADR-005（服务端 QuickJS-wasm）对称——本文是同一根承重墙（"一份 adapter，两端同一引擎"）的客户端落点。

---

## 1. 背景（Context）

ADR-001 §8 把"客户端 QuickJS 与服务端 QuickJS-wasm 对同一夹具产出一致"定为 CI 闸门。ADR-005 已敲定服务端用 QuickJS-wasm。客户端是 Flutter/Dart，需要一个 **Dart 侧的 QuickJS 绑定**来执行 adapter——本文解决"用哪个绑定、怎么执行、校验边界在哪"。

实践中发现 Dart 侧"全平台 QuickJS"的生态又薄又脆，这本身是影响该承重墙可行性的关键事实，必须记录。

---

## 2. 决策（Decision）

1. **引擎：所有平台都用 QuickJS（含 iOS）。** 选 `flutter_qjs`（ekibun 谱系，`dart:ffi` 绑定 QuickJS）。**显式拒绝 `flutter_js`**——它在 iOS/macOS 用 JavaScriptCore，等于客户端在 iOS 上换了引擎，**重新引入语义漂移**（正是 ADR-005 否掉 goja 的同一类理由，只是发生在客户端）。
2. **后台 isolate 执行。** 用 `IsolateQjs`，adapter 不在 UI 线程同步阻塞（红线 #7）。
3. **加载约定与服务端对齐：以 ES module 加载 adapter、取其 `capabilities` 导出。** 客户端经 `moduleHandler` + `import` 包装拿到导出，产出以 JSON 字符串跨边界回传；服务端经 `quickjs-emscripten` 的模块命名空间返回。两端都以**模块作用域（严格模式）**加载同一份源码，产出由 golden 比对保证一致。
4. **校验边界在 Dart 宿主，不在 QuickJS。** adapter 产出由客户端核心按 `contract/schema/` 校验后才接受（ADR-001 §2.2：QuickJS 不背校验器）。
5. **parser 模式先行。** 当前实现仅 parser（无网络、无凭证、ctx 仅 `log`/`now`）。**fetch 模式的受限 `ctx.fetch` + 凭证白名单注入是承重 + 安全敏感路径（红线 #1、AGENTS.md §1），单独走人工审阅的 PR。**
6. **执行限额对齐服务端 `DEFAULT_LIMITS`**（timeout 5s、memory 64MiB），由 `IsolateQjs` 的 `timeout`/`memoryLimit` 强制。

### 2.1 选型对比

| 候选 | 取 | 舍 |
|---|---|---|
| **flutter_qjs（ekibun，选用）** | 全平台 QuickJS，与服务端**同一引擎零漂移**；纯 ffi；API 干净；自带 cxx/QuickJS 源 | **已停更（2022 后）**，0.3.7 在 Dart 3.12 编不过（见 §4） |
| flutter_js | 维护中 | **iOS/macOS 用 JavaScriptCore** → 引擎漂移，违背承重墙 |
| kodjodevf/flutter_qjs | 较新 | 实为 flutter_js 改名（`getJavascriptRuntime` API），v0.0.1、未发 pub，来路不稳，不宜作承重依赖 |

---

## 3. 已知约束与风险（Consequences）

这些是本决策"不埋雷"的前提，必须随实现一起兜住：

1. **绑定已停更、需打补丁的 fork。** ekibun `flutter_qjs` 0.3.7 的 FFI 回调返回可空指针，Dart 3.12 更严的 `Pointer.fromFunction` 编译失败。落地方式：`pubspec.yaml` 用 `dependency_overrides` 指向打了**一行兼容补丁**的 fork（[`NanCunChild/flutter_qjs@dart3-compat`](https://github.com/NanCunChild/flutter_qjs/tree/dart3-compat)），**pin 到具体 commit**。
   - **补丁内容**（`lib/src/ffi.dart`）：`channelDispacher` 的返回类型由 `Pointer<JSValue>?` 改为非空 `Pointer<JSValue>`，函数体末尾 `... ?? nullptr` 兜底。仅此一处，纯 Dart、不动 C 源，便于审计与未来迁移。
   - *风险*：自带一个 fork 的维护负担，与"低维护"主线相悖。
   - *缓解*：补丁极小且可审计；pin commit 保证可复现；中长期应评估迁移到维护良好的全平台 QuickJS 绑定（若出现）或自管最小 ffi 层。
2. **pub 不为 git 依赖初始化 submodule。** ekibun 把 QuickJS 源作为 git submodule，经 git ref 消费时为空，会同时打断原生插件构建与 FFI 测试库。fork 已将 QuickJS 源 **vendoring**（提交为普通文件）以自包含。
3. **原生测试库需预构建。** `flutter_qjs` 是经典插件，纯 `flutter test`（host VM）不构建原生库；但其 ffi 在 `FLUTTER_TEST` 下从 `test/build/libffiquickjs.so` 加载。故用 `client/tool/build_qjs_test_lib.sh` 经 CMake 预构建该库，即可无显示器跑测试。**当前 desktop 测试基建仅 Linux**，其余平台按需补。
4. **iOS App Store 审核（开放项，[#4](https://github.com/NanCunChild/elecon/issues/4)）。** 在 iOS 上下载并由内置解释器执行 adapter JS，触及指南 2.5.2（下载可执行代码）。QuickJS 是解释器、无 JIT，不触 JIT 禁令，但"执行下载代码"本身需在发布前做合规评估（与 fetch 模式凭证注入一并处理）。
5. **两端加载机制不同但语义对齐。** 服务端用模块命名空间返回、客户端用 import 包装 + global 暴露——都以 ESM/模块作用域加载同一份源码，产出由 golden 双跑闸门兜底。后续可考虑收敛为同一 bootstrap 以进一步降低漂移面。
6. **两端是同一 Bellard 谱系的【两个不同版本 + 不同编译配置】，不是同一份字节码。** §2 "字面意义上同一引擎" 指引擎家族；2026-06 核查实测的真实情况是：

   | 端 | 引擎 | QuickJS 源版本 | BigInt |
   |---|---|---|---|
   | 服务端 | `quickjs-emscripten@0.31` `RELEASE_SYNC`（`@jitl/quickjs-wasmfile-release-sync`，**非** `quickjs-ng`） | Bellard **2024-02-14**（commit `36911f0d`） | 有 |
   | 客户端 | `flutter_qjs` fork vendored | Bellard **2021-03-27** | **无** |

   两者**同谱系**（都不是 quickjs-ng，避开了分叉级漂移），但隔着两类差异：
   - **版本差（2021→2024）**：客户端缺 ES2022+ 内建——`Array/String.prototype.at`、`findLast`/`findLastIndex`、`toSorted`/`toReversed`/`toSpliced`/`with`、`Object.groupBy`/`Map.groupBy`。adapter 用了它们 → 服务端跑过、客户端抛 `TypeError`。
   - **编译配置差**：`flutter_qjs` 的 CMake 未传 `-DCONFIG_BIGNUM`，客户端**整个关闭了 BigInt**——`2n` 字面量直接解析报错（此事实由本 ADR 落地的 engine-floor canary 首跑抓到）。

   *风险*：上述特性在「恰好命中的 fixture」之外漏过 CI；其中 BigInt 是硬解析错误、影响面最大。另注：客户端 `_mapEngineError` 靠英文子串 `interrupt`/`out of memory` 分类超时/内存——该文案在不同 QuickJS 版本间无稳定保证，版本错配会放大误判面（暂由两端各自识别、不跨端比对来规避）。

   *缓解（本 ADR 落地）*：
   - **engine-floor canary**（`adapters/_canary/parser/`，capability `__canary.engine_floor`）只调用**实测的共同地板**内建，断言产出 == golden，挂在双跑闸门两侧（服务端 `sandbox.smoke.ts`、客户端 `dual_run_test.dart`）当**回归哨兵**：任一侧地板特性漂移即变红。其 `avoided` 列表把"adapter 不得依赖的能力"钉进 golden。
   - **作者约束**：parser/fetch adapter 必须按客户端地板编写，不得依赖 `avoided` 列出的内建，直至客户端引擎对齐。

   *迁移触发*：当 (a) 需要 BigInt / ES2022+，或 (b) canary 暴露的地板缺口变宽到约束 adapter 作者时——把客户端 fork 的 vendored QuickJS 升到 2024-02-14 并开 `CONFIG_BIGNUM` 以对齐服务端。这恰是 §3.1「评估自管最小 ffi 层」的触发点：一旦要动原生 QuickJS 源，即到了把用到的那块 vendoring 进仓库做一方代码的时机（而非全自写 FFI）。

---

## 4. 落地清单（指向 `client/` 骨架）

- `client/lib/core/adapter_runtime.dart`：parser 模式运行时（`IsolateQjs` 后台 isolate、ESM/moduleHandler 加载、JSON 跨边界、ctx 仅 log/now、限额对齐服务端、失败用 `AdapterFailureReason` 表达且不携带契约 error.kind）。
- `client/test/dual_run_test.dart`：双跑一致性（客户端半边）+ capability_missing / async_in_parser 反例 + engine-floor canary。
- `adapters/_canary/parser/`：引擎地板漂移哨兵（`__canary.engine_floor`）。两端共有内建的 golden + `avoided` 约束清单；服务端半边在 `server/src/runtime/sandbox.smoke.ts`。
- `client/tool/build_qjs_test_lib.sh`：从 `package_config.json` 动态定位 flutter_qjs、经 CMake 构建 FFI 测试库。
- `client/pubspec.yaml`：`flutter_qjs` 依赖 + 指向补丁 fork 的 `dependency_overrides`（pin commit）。
- 待续：fetch 模式 `ctx.fetch` + 凭证注入（红线 #1，人工审阅 PR，[#3](https://github.com/NanCunChild/elecon/issues/3)）；iOS 2.5.2 合规评估（[#4](https://github.com/NanCunChild/elecon/issues/4)）；其余平台 desktop/device 测试基建。
