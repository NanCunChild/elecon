# ADR-008：客户端 adapter 执行运行时（QuickJS / Flutter）

- **状态**：已接受（Accepted，修订 2026-07-16）
- **日期**：2026-06-09
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)、[`adr_001_contract.md`](./adr_001_contract.md)、[`adr_005_runtime.md`](./adr_005_runtime.md)
- **适用范围**：`client/` 客户端对 adapter 的执行栈。与 ADR-005（服务端 QuickJS-wasm）对称——本文是同一根承重墙（"一份 adapter，两端同一引擎"）的客户端落点。

> 2026-07-10 实施注记：主线已从旧 `flutter_qjs` 补丁 fork 迁移到 `flutter_qjs_next`。
> 2026-07-16 修订：客户端改用 pub.dev **精确版本 `flutter_qjs_next: 1.0.2`**，
> `pubspec.lock` 固定 hosted 包 SHA-256；包许可证为 MIT，Dart SDK 下限统一为 `>=3.10.0`。
> 保留 `IsolateQjs`/host-fn 通道；QuickJS 源版本为 2026-06-04；OHOS 旁路线仍待单独验证。

---

## 1. 背景（Context）

ADR-001 §8 把"客户端 QuickJS 与服务端 QuickJS-wasm 对同一夹具产出一致"定为 CI 闸门。ADR-005 已敲定服务端用 QuickJS-wasm。客户端是 Flutter/Dart，需要一个 **Dart 侧的 QuickJS 绑定**来执行 adapter——本文解决"用哪个绑定、怎么执行、校验边界在哪"。

实践中发现 Dart 侧"全平台 QuickJS"的生态又薄又脆，这本身是影响该承重墙可行性的关键事实，必须记录。

---

## 2. 决策（Decision）

1. **引擎：所有平台都用 QuickJS（含 iOS）。** 主线使用 `flutter_qjs_next`（ekibun 谱系延续，`dart:ffi` 绑定 QuickJS）。**显式拒绝 `flutter_js`**——它在 iOS/macOS 用 JavaScriptCore，等于客户端在 iOS 上换了引擎，**重新引入语义漂移**（正是 ADR-005 否掉 goja 的同一类理由，只是发生在客户端）。
2. **后台 isolate 执行。** 用 `IsolateQjs`，adapter 不在 UI 线程同步阻塞（红线 #7）。
3. **加载约定与服务端对齐：以 ES module 加载 adapter、取其 `capabilities` 导出。** 客户端经 `moduleHandler` + `import` 包装拿到导出，产出以 JSON 字符串跨边界回传；服务端经 `quickjs-emscripten` 的模块命名空间返回。两端都以**模块作用域（严格模式）**加载同一份源码，产出由 golden 比对保证一致。
4. **校验边界在 Dart 宿主，不在 QuickJS。** adapter 产出由客户端核心按 `contract/schema/` 校验后才接受（ADR-001 §2.2：QuickJS 不背校验器）。
5. **declarative requestGraph 先行。** 早期实现仅 declarative（无网络、无凭证、ctx 仅 `log`/`now`）。**imperative 的受限 `ctx.fetch` + 凭证白名单注入是承重 + 安全敏感路径（红线 #1、AGENTS.md §1），单独走人工审阅的 PR。**
6. **执行限额对齐服务端 `DEFAULT_LIMITS`**（timeout 5s、memory 64MiB），由 `IsolateQjs` 的 `timeout`/`memoryLimit` 强制。

### 2.1 选型对比

| 候选 | 取 | 舍 |
|---|---|---|
| **flutter_qjs_next（当前主线）** | 全平台 QuickJS；与服务端同属 QuickJS 谱系并以共享 golden/canary 约束已使用语义；纯 ffi；保留 `IsolateQjs`/host-fn；QuickJS 2026-06-04；解除旧 KGP/ffi 1.x 阻塞 | 与服务端绑定、版本和编译配置不同；当前以 pub.dev `1.0.2` 精确版本接入；MIT；OHOS 未验证 |
| flutter_qjs（ekibun，旧方案） | 全平台 QuickJS；API 干净；自带 cxx/QuickJS 源 | 已停更，0.3.7 在 Dart 3.12 编不过；旧 fork 拖累 ffi/KGP |
| flutter_js | 维护中 | **iOS/macOS 用 JavaScriptCore** → 引擎漂移，违背承重墙 |
| kodjodevf/flutter_qjs | 较新 | 实为 flutter_js 改名（`getJavascriptRuntime` API），v0.0.1、未发 pub，来路不稳，不宜作承重依赖 |

---

## 3. 已知约束与风险（Consequences）

这些是本决策"不埋雷"的前提，必须随实现一起兜住：

1. **绑定仍是承重第三方依赖。** `flutter_qjs_next 1.0.2` 已吸收 Dart 3/host-fn/timeout/memoryLimit/event loop 等能力，并升到 QuickJS 2026-06-04；当前以 pub.dev 精确版本接入，许可证为 MIT。
   - *风险*：发布包的原生平台内容、pub.dev 可用性和上游维护状态仍影响构建。
   - *缓解*：`pubspec.lock` 固定 hosted SHA-256；升级版本必须重跑 host-fn/dual-run/imperative 与 release gate。
2. **发布包必须自包含原生源。** 当前 `1.0.2` 通过 pub.dev 分发，QuickJS 源与 Linux `example/` 已随包发布；若未来发布包缺少平台源或头文件，原生构建会在测试阶段 fail-closed。
3. **原生测试库需预构建。** `flutter_qjs_next` 是经典插件，纯 `flutter test`（host VM）不构建原生库。`client/tool/build_qjs_test_lib.sh` 从 package config 定位 hosted 包，复制到临时目录并清理 `build/`/`.dart_tool/` 缓存；若发布包不含 example，则生成最小 Linux 宿主工程，再通过 `FLUTTER_QJS_NEXT_LIBRARY` 指向 `libflutter_qjs_next_plugin.so` 跑测试。**当前 desktop 测试基建仅 Linux**，其余平台按需补。
4. **iOS App Store 审核（已由 [ADR-010](./adr_010_ios_appstore.md) 定调，[#4](https://github.com/NanCunChild/elecon/issues/4)）。** 在 iOS 上下载并由内置解释器执行 adapter JS，触及指南 2.5.2（下载可执行代码）。QuickJS 是解释器、无 JIT，不触 JIT 禁令。合规依据走 **DPLA §3.3.2**（解释型代码：不改变主要用途 / 非代码市场 / 不绕过系统安全）——本运行时的"无 JIT、沙箱内 background isolate 执行"满足其 (c)；"固定能力集、adapter 只产出已知 schema"满足其 (a)。详见 ADR-010。
5. **两端加载机制不同但语义对齐。** 服务端用模块命名空间返回、客户端用 import 包装 + global 暴露——都以 ESM/模块作用域加载同一份源码，产出由 golden 双跑闸门兜底。后续可考虑收敛为同一 bootstrap 以进一步降低漂移面。
6. **两端是同一 Bellard 谱系的【两个不同版本 + 不同编译配置】，不是同一份字节码。** §2 "字面意义上同一引擎" 指引擎家族；2026-06 核查实测的真实情况是：

   | 端 | 引擎 | QuickJS 源版本 | BigInt |
   |---|---|---|---|
   | 服务端 | `quickjs-emscripten@0.31` `RELEASE_SYNC`（`@jitl/quickjs-wasmfile-release-sync`，**非** `quickjs-ng`） | Bellard **2024-02-14**（commit `36911f0d`） | 有 |
   | 客户端 | `flutter_qjs_next 1.0.2` | Bellard **2026-06-04** | 待以 canary/adapter 约束兜底 |

   两者**同谱系**（都不是 quickjs-ng，避开了分叉级漂移），但仍不是同一份字节码；客户端版本现在反而新于服务端。adapter 作者仍不得假设任意新内建可用，必须以 engine-floor canary 和共享 fixture 为准。

   *风险*：客户端新于服务端后，adapter 若误用服务端 QuickJS-wasm 尚不支持的 ES2025+ 行为，仍可能出现「客户端过、服务端不过」的反向漂移。另注：客户端 `_mapEngineError` 靠英文子串 `interrupt`/`out of memory` 分类超时/内存——该文案在不同 QuickJS 版本间无稳定保证，版本错配会放大误判面（暂由两端各自识别、不跨端比对来规避）。

   *缓解（本 ADR 落地）*：
   - **engine-floor canary**（`adapters/_canary/declarative/`，capability `__canary.engine_floor`）只调用**实测的共同地板**内建，断言产出 == golden，挂在双跑闸门两侧（服务端 `sandbox.smoke.ts`、客户端 `dual_run_test.dart`）当**回归哨兵**：任一侧地板特性漂移即变红。其 `avoided` 列表把"adapter 不得依赖的能力"钉进 golden。
   - **作者约束**：declarative/imperative adapter 必须按双端共同地板编写，不得依赖 `avoided` 列出的内建，直至 canary 和服务端 QuickJS 同步放开。

   *迁移触发*：当 canary 暴露双端共同地板不足时，优先评估升级服务端 QuickJS-wasm 或调整 adapter 作者约束；客户端 `flutter_qjs_next` 自身的版本地板已不再是当前主阻塞。

---

## 4. 落地清单（指向 `client/` 骨架）

- `client/lib/core/adapter_runtime.dart`：declarative requestGraph 运行时（`IsolateQjs` 后台 isolate、ESM/moduleHandler 加载、JSON 跨边界、ctx 仅 log/now、限额对齐服务端、失败用 `AdapterFailureReason` 表达且不携带契约 error.kind）。
- `client/test/dual_run_test.dart`：双跑一致性（客户端半边）+ capability_missing / async_in_declarative 反例 + engine-floor canary。
- `adapters/_canary/declarative/`：引擎地板漂移哨兵（`__canary.engine_floor`）。两端共有内建的 golden + `avoided` 约束清单；服务端半边在 `server/src/runtime/sandbox.smoke.ts`。
- `client/tool/build_qjs_test_lib.sh`：从 `package_config.json` 动态定位 hosted `flutter_qjs_next`，清理复制缓存；必要时生成最小 Linux 宿主工程，构建测试用原生库。
- `client/pubspec.yaml`：`flutter_qjs_next: 1.0.2`（pub.dev 精确版本）；升级必须同步 `pubspec.lock` 并重跑完整客户端验证。
- 待续：imperative `ctx.fetch` + 凭证注入（红线 #1，人工审阅 PR，[#3](https://github.com/NanCunChild/elecon/issues/3)）——客户端宿主函数桥接见 [ADR-014](./adr_014_client_host_fn.md)；iOS 2.5.2 合规评估（已由 [ADR-010](./adr_010_ios_appstore.md) 给出可上架形态，[#4](https://github.com/NanCunChild/elecon/issues/4)）；其余平台 desktop/device 测试基建。
