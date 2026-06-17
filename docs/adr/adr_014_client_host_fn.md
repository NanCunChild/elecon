# ADR-014：fetch 模式客户端宿主函数桥接（IsolateQjs 宿主函数通道扩展）

- **状态**：已接受（Accepted，2026-06-17 经人工 review 后接受）。本文触碰红线 #1（凭证）与 #7（后台 isolate），且改动客户端 QuickJS 承重依赖（flutter_qjs fork）。按 [AGENTS.md](../../AGENTS.md) §1 + §10，**AI 不得独自闭环**：本草案由 AI 起草、经人工 review 后接受；**实现（fork 扩展 + adapter_runtime 接线）及其测试仍须人工主导 + 安全检查清单 + ≥1 人工审**。
- **日期**：2026-06-17
- **依赖**：[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（客户端 QuickJS / `IsolateQjs` / fork）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（fetch 凭证注入数据流 §2.1 / 限额 §2.7）、[`adr_005_runtime.md`](./adr_005_runtime.md)（两端同一引擎）、[`adr_001_contract.md`](./adr_001_contract.md) §8（双跑闸门）
- **适用范围**：`client/lib/core/adapter_runtime.dart` 的 **fetch 模式**接线，及其所依赖的 `flutter_qjs` fork 引擎扩展。是 ADR-008 §2.5 / §4「待续：fetch 模式 `ctx.fetch`」的落点。

---

## 1. 背景（Context）

服务端 fetch 运行时已落地（B6b-TS，PR #51）：`server/src/runtime/sandbox.ts` 的 `runFetchAdapter` 用 `quickjs-emscripten` 原生的 `newFunction`（暴露宿主函数）+ `newPromise`（宿主侧异步 → VM Promise）+ `executePendingJobs`（pump job queue），把受限 `ctx.fetch` 接到 B6a 的 `proxyFetch`。客户端需对称落地（B6b-Dart），但**Dart 侧缺一项 TS 侧白来的能力**。

**事实（2026-06-17 通读 fork `fd7273` 实证）**：

- ADR-008 §2.2 定的 **`IsolateQjs`（后台 isolate，红线 #7）只有两类跨 isolate 消息：`#evaluate`（求值脚本串）与 `#close`**。**没有把宿主 Dart 函数注入 VM 全局、供 JS 调用的通道。** 唯一的跨边界宿主异步回调是 `moduleHandler`（用于模块解析，且 isolate 内以 `sleep` 忙等同步阻塞拿模块串）与 `hostPromiseRejectionHandler`。
- **parser 模式之所以可行**：它零宿主回调——`ctx.log` 是 JS 空函数、`ctx.now` 注入字面量、入参经 `JSON.parse` 字面量注入、产出读 `globalThis.__elecon_outcome`。全程不需要 JS→Dart 的运行期回调。
- **fetch 模式必须有**异步 `ctx.fetch`：JS `await ctx.fetch(url, init)` → 回调 Dart 宿主跑 `proxyFetch`（B1 注入/B2 净化/B3 重定向/B4 jar/resolver，**凭证仅核心可见**）→ 把脱敏响应交回 JS。这是一条 JS→Dart 的运行期异步回调，`IsolateQjs` 当前给不了。

非 isolate 的 `FlutterQjs` 引擎**支持**宿主函数（Dart 函数返回 `Future` → JS `Promise`），但用它跑 adapter **违反红线 #7**（adapter 必须后台 isolate，不在 UI 线程同步阻塞）。故不能退到非 isolate 引擎。

**关键利好**：fork 的跨 isolate 编解码 **已内建 `Future` 往返**（`isolate.dart` 的 `_encodeData`/`_decodeData` 对 `#jsFuturePort` 的处理）与 **`IsolateFunction`**（`_IsolateEncodable`，可跨 isolate 传递的 Dart 闭包包装）。即异步桥接的底层管线已存在，缺的是**把宿主函数注入 VM 全局**的那一段接线。

---

## 2. 决策（Decision，草案）

1. **扩展项目自有的 `flutter_qjs` fork，给 `IsolateQjs` 增一条窄宿主函数通道**，使 `adapter_runtime.dart` 能在后台 isolate 内向 VM 全局注入受限 `ctx`（`fetch` / `setEphemeralCookie` / `log` / `now`），JS 调用经 isolate port 回到主 isolate 的 Dart 宿主执行、返回 `Future` → JS `Promise`。**复用 fork 已有的 `IsolateFunction` + `#jsFuturePort` 异步管线**，新增面尽量小。
   - **形态（待实现细化）**：`IsolateQjs` 求值前接受一组宿主绑定（`Map<String, IsolateFunction>` 或等价），worker 在 `#evaluate` 前把它们 `setProperty` 到 `globalThis`（或经一个内建 bootstrap 注入到 `ctx`）。JS 调用该函数 → `IsolateFunction` 经其 port 路由回主 isolate 的 Dart 闭包 → 闭包返回 `Future`（跑 `proxyFetch`）→ 经 `#jsFuturePort` 编码回 isolate → VM 得到一个会 settle 的 `Promise`。pump 由引擎 `dispatch()` 既有事件循环驱动。
   - **注入时机钉死「求值前一次性」**：宿主绑定在 `#evaluate` 前一次性注入，**运行时不可追加/动态增减**——更简单、攻击面更小（adapter 无法在执行中协商出新宿主能力）。运行期动态绑定不在本决策范围。
   - **补丁极小、纯 Dart、不动 vendored C 源**（与 ADR-008 §3.1 的 dart3-compat 一行补丁同精神），**pin 到具体 commit**，便于审计与复现。

2. **宿主只暴露 broker 中介过的受限面，凭证永不入 isolate / JS。** 经此通道暴露给 JS 的宿主函数**仅**：
   - `ctx.fetch(url, init)` → 主 isolate 跑 `proxyFetch`（凭证在**主 isolate 核心内**拼头、出网、脱敏）；**跨回 isolate 的只有脱敏后的 `{status, headers, body}`**——无凭证值、无 `Set-Cookie`、无 `Authorization` 回显、无中间 `Location`（B2/B3 已剥）。
   - `ctx.setEphemeralCookie(name, value, {domain, path?})` → 主 isolate 的 per-execution jar ephemeral 分区（四重栅栏由 B4 强制）。
   - `ctx.log` / `ctx.now`（与 parser 同）。
   - **入参方向**：JS→Dart 只传 `url` + `init`（method/headers/body）。adapter 自设的 Cookie/Authorization 由 `proxyFetch` 内 B2 无条件剥除（纵深防御不变）。

3. **限额与收割语义与 TS 对齐**（ADR-009 §2.7）：单请求 10s（含重定向链）/ 累计 30s / 单次 ≤20 请求（每跳计一次，计划 §8 #3）；超限 → 终止执行、fail 不收割。执行结束 B5 收割钩子（`decideHarvest`+`harvestInto`）。这些在 `adapter_runtime.dart` 宿主侧实现，与 `sandbox.ts` 镜像。

4. **两端无共享 golden，各自集成测试**（计划 §2：运行时触引擎、不可纯 golden 化）。两端共享的是 `proxyFetch` 逻辑（`fetch_proxy.dart` 已镜像 `fetch-proxy.ts`，由纯 Dart fake-transport 测试钉死）；引擎接线各端用 fake transport 驱动集成 smoke（服务端 `sandbox.fetch.smoke.ts`，客户端新增 `adapter_runtime` fetch 集成测试）。

5. **parser 路径零扰动。** parser 不经此通道（零宿主回调），fetch 通道为**新增**、对 parser 不可见；engine-floor canary（ADR-008 §3.6）继续在双跑闸门两侧守地板漂移。

---

## 3. 备选与取舍（Alternatives）

| 方案 | 取舍 | 裁定 |
|---|---|---|
| **A. 扩 fork 宿主函数通道（本 ADR 选）** | 干净、与 TS 语义一致、可复用；复用 fork 已有的 Future/IsolateFunction 管线，新增面小。代价：fork 维护/审计负担加重（叠加 ADR-008 §3.1 的既有 fork）。 | **选用** |
| B. `moduleHandler` 当 fetch 桥接（hack） | `ctx.fetch` 用 `await import('elecon:fetch/<nonce>/<payload>')`，moduleHandler 主 isolate 解码跑 `proxyFetch`、返回 `export default <json>`。不改引擎、现有 fork 可跑。**舍**：①滥用模块系统语义；②isolate 内 `sleep` 忙等阻塞背景线程（每次出网烧 CPU）；③请求 payload 塞模块名（长度/编码隐患）；④需 nonce 防模块缓存；⑤🔒 凭证承重路径走 hack，审计与演进面恶化。 | 拒绝 |
| C. fetch adapter 改用非 isolate `FlutterQjs` | 直接支持宿主函数。**舍**：违反红线 #7（必须后台 isolate）。 | 拒绝 |

---

## 4. 已知约束与风险（Consequences，草案）

1. **fork 增量大于 §3.1 的一行补丁。** 这是该 fork 的**第二处、且更实质**的改动（宿主函数通道）。维护/审计负担上升，与「低维护」主线相悖。*缓解*：补丁尽量窄（复用既有 `IsolateFunction`/`#jsFuturePort`，不新写异步原语）、纯 Dart、pin commit、在 ADR-008 §3.1 的 fork 谱系记录里登记；中长期与「迁移到维护良好的全平台 QuickJS 绑定 / 自管最小 ffi 层」（ADR-008 §3.1 触发点）一并评估。
2. **凭证边界是本通道的核心安全断言（红线 #1）。** isolate/JS 侧**永不**持有凭证值：`proxyFetch` 全程在主 isolate 核心内跑，跨回 isolate 的仅脱敏 `{status, headers, body}`。**风险**：若未来有人往该通道加暴露更多宿主能力（如把 resolver/jar 直接暴露给 JS），即破红线 #1。*缓解*：通道暴露面在 ADR 与 code review 钉死为「仅 broker 中介的 fetch/setEphemeralCookie/log/now」；扩面须改本 ADR + 安全清单复审。
3. **每次 `ctx.fetch` 多一对 isolate↔主 isolate port 往返**的延迟。网络耗时占主导，可接受。
4. **限额硬执行落在 Dart 宿主**（墙钟在主 isolate 计时，与 isolate 内引擎 `timeout` 互补）。需确保超限能**终止执行**（不只是拒单次 fetch），与 `sandbox.ts` 的 `fatal` 语义一致。**⚠️ Open question（实现前须拍板）**：`IsolateQjs` 的 `timeout` interrupt **只在同步 `evaluate` 求值期生效**；一旦 JS `await ctx.fetch` 把控制权交回、引擎进入空闲等 host `Promise` settle 的状态，**引擎不在执行态，interrupt handler 打不到**——纯靠引擎 timeout 无法终止「卡在 await 上的」执行。
   - TS 端对此已有解：除 `setInterruptHandler(deadline)` 外，`runFetchAdapter` 在 `resolvePromise` 外套 host 侧 `withTimeout` race（主 isolate 计时），单请求 10s 与墙钟双重兜底。Dart 端**单请求**同样可由主 isolate 的 host 侧 `withTimeout` 兜（不依赖引擎 interrupt）。
   - 但**执行级超限 / 卡死的 worker isolate** 仍需一个**主动中止 worker** 的手段，候选：
     - **(a) 主 isolate 不 resolve deferred + 依赖 isolate 内 event loop 空闲退出**——须先确认 fork 的 `dispatch()` 事件循环是否有内建空闲超时（**待核**，倾向「无」）。
     - **(b) 新增 `#abort` 消息**——主 isolate 发 abort → worker 设标记 → 下次 `executePendingJobs` 前检查并抛出终止。需 fork 配合（与本 ADR 的通道扩展同批）。
     - **(c) `Isolate.kill()` 硬杀**——有效但粗暴，可能泄漏 isolate 内 C/FFI 句柄（见 §4.7）。
   - **倾向**：单请求/累计墙钟由 host 侧 `withTimeout` 兜（主路径）；worker 真卡死时以 (b) `#abort` 为主、(c) `Isolate.kill()` 兜底。实现前在落地 PR 定稿。
5. **两端引擎接线不同、语义靠测试对齐**（无共享 golden）。两端跑 `proxyFetch` 同一逻辑（已镜像），但引擎 pump/Promise 桥接各异——回归靠各端集成 smoke + 既有 engine-floor canary。
6. **🔒 承重 + 安全敏感 + 触引擎。** fork 扩展与 `adapter_runtime.dart` fetch 接线及其测试，按 AGENTS.md §1 不得 AI 独自闭环，须人工主导 + 安全清单 + ≥1 人工审。
7. **isolate 终止时 in-flight `proxyFetch` / transport 请求的清理（⚠️ open question）。** 若 worker isolate 因超限/超时被中止，而主 isolate 上有一个 `proxyFetch` 正 `await transport.fetch(...)`：① 该 transport 请求需 graceful cancel 还是 leak-and-GC？② 若走 (c) `Isolate.kill()`，对应 deferred 永不 settle，但 transport 可能仍在飞、其响应（含潜在凭证等价物）落地无人消费。**倾向**：transport seam（ADR-003）须支持 cancel（如 `CancelToken`），执行终止时取消所有 in-flight 请求；落地前在 transport 接口定稿时一并确定。属本 ADR 与 ADR-003 的接口对接点。

---

## 5. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

- **fork 扩展** ✅（commit `0dd8069`，分支 `feat/host-fn-channel`；elecon 接入 PR #54）：`NanCunChild/flutter_qjs` 增 `IsolateQjs.setHostFunctions` 宿主函数通道（复用 `IsolateFunction` + Future→Promise）；纯 Dart、仅 `isolate.dart`、不动 vendored C；`client/pubspec.yaml` ref `fd7273→0dd8069`；`build_qjs_test_lib.sh` 已重建（C 源不变、ABI 兼容）。桥接证明 `test/host_fn_bridge_test.dart` 4/4（Future→Promise 往返 / 多次调用 / 抛错→reject / inject-once）。
- **`client/lib/core/adapter_runtime.dart`**：增 `runFetchAdapter`（与 parser `runParserAdapter` 并列、互不干扰）——受限 `ctx.fetch` → `proxyFetch`、`ctx.setEphemeralCookie`、限额硬执行（10s/30s/≤20）、执行结束 B5 收割钩子；与 `sandbox.ts` 镜像。
- **客户端 fetch 集成测试**：fake transport 驱动（镜像 `sandbox.fetch.smoke.ts` 4 例：inject+脱敏+收割 / 多步握手 ephemeral / fail-closed 可 catch / 请求数限额+fail 不收割）。
- **已就绪前置**（B6b-Dart 第一部分，分支 `gate-a/b6b-fetch-runtime-dart`）：`fetch_proxy.dart`（proxyFetch + Transport 镜像）+ `cookie_jar.dart` `selectForSend` + 驱动测试 6 例——纯 Dart、与引擎解耦，已绿。
- **交叉引用更新**：ADR-008 §4「待续 fetch 模式」指向本 ADR；ADR-000 §6 索引登记。

---

## 附录 A：修订记录

| 日期 | 版本 | 摘要 |
|---|---|---|
| 2026-06-17 | 草案 | 起草：IsolateQjs 无宿主函数通道阻塞 B6b-Dart；选「扩 fork 宿主函数通道」（拒 moduleHandler-hack / 非 isolate 引擎）；凭证永不入 isolate 为核心安全断言。🔒 待人工 + 安全清单复核后接受。 |
| 2026-06-17 | 草案 rev-a（PR #52 review 跟进）| §2.1 钉死宿主绑定「求值前一次性注入、运行时不可追加」；§4.4 补 open question——IsolateQjs interrupt 仅同步求值期生效、卡 await 时打不到，列终止手段 (a)/(b)/(c) + 倾向（host withTimeout 主路径 + `#abort` 兜底）；§4 增第 7 条 in-flight transport 清理 open question（对接 ADR-003 cancel）。 |
| 2026-06-17 | 已接受 | 经人工 review 后接受。§5 fork 扩展落地标 ✅（fork commit `0dd8069`/分支 `feat/host-fn-channel`，elecon 接入 PR #54；桥接证明 4/4、全套 Dart 123/123 无回归）。剩余落地项（adapter_runtime 接线 / fetch 集成测试）仍 🔒 待实现 + 人工审。 |
