# B6 实现计划 · 受限 ctx.fetch 代理 + 异步 handler 运行时 + 限额

> 状态：**核心零件已落地（2026-07-14）**——`fetch-proxy.ts` / `fetch_proxy.dart`（`proxyFetch` 逐跳注入 +
> 自跟随重定向 + 捕获 Set-Cookie）+ 集成测试入库；§8 开放点实现时已定。本文留作**实现依据 / 历史**。
> 实现属 🔒 安全敏感承重路径（红线 #1 凭证注入 + 出网），
> 按 [AGENTS.md](../../AGENTS.md) §1 **AI 不得独自闭环**。
> 依据：[ADR-009](../adr/adr_009_fetch_credential.md) §2.1（数据流）/ §2.5 / §2.7（限额）/ §2.8 ·
> [ADR-003](../adr/adr_003_transport.md)（transport 出网）· [ADR-005](../adr/adr_005_runtime.md)（QuickJS 双端）·
> [Track B 计划](./track_b_fetch_runtime_plan.md) §2 B6。
> 前置：B1 注入决策（#28/#31）· B2 头净化（#29）· B3 重定向（#30）· B4 cookie jar（#37/#38）·
> 凭证存储（#32/#33）· B5 收割桥接（计划中）。

## 0. 这件事是什么

B6 是把 **B1–B5 各零件 + 凭证 resolver + transport 出网**编织成真正可跑的受限
`ctx.fetch` 的**集成层**，并提供**异步 handler 运行时**（QuickJS job queue pump/await）
与**资源限额**。这是 fetch 模式从「零件齐备」到「端到端可执行」的最后一步，也是首个
**触及 QuickJS 引擎本身**（非纯逻辑）的 broker 件。

## 1. 范围

**含**：
- **ctx.fetch 代理（请求拼装）**：单次 `ctx.fetch(url, init)` 的完整宿主侧管线：
  ① B1 `decideInjection` → reject/passthrough/inject
  ② resolver 取值（仅 inject）+ B4 jar `selectCookies` 合并 → 拼 Cookie/Authorization
  ③ B2 `sanitizeRequestHeaders` 净化出站头
  ④ transport 发请求（seam）→ B4 `captureSetCookie` 吃响应 Set-Cookie
  ⑤ B3 `followRedirects` 自跟随（每跳同样吃 Set-Cookie）
  ⑥ B2 `sanitizeResponseHeaders` 脱敏 → 交回 adapter
- **异步 handler 运行时**：QuickJS job queue pump + await fetch Promise（两端 sandbox/adapter_runtime）。
- **限额**（ADR-009 §2.7）：单请求 10s／单次执行累计 30s／单次执行 ≤20 请求；超限 fail。
- **执行结束钩子**：调 B5 `decideHarvest`+`harvestInto` 收割（接 B5 的接线点）。

**不含**（划走）：
- 真实 transport 实现（ADR-003，VPN/直连/中继）——B6 经 seam 注入，transport 本体另件。
- B5 收割决策本身（B6 只调用其接线点）。
- B7 录制/回放夹具机制；B8 后置 token 审计。

## 2. 与 B1–B5 不同：B6 不是纯 golden 件

B1–B5 是**纯决策**，golden 双跑钉两端。B6 的**请求拼装管线**仍可大部分抽成纯函数
`assembleRequest` / `processResponse`（golden 双跑）；但**异步运行时 + 限额 + transport 驱动**
触及 QuickJS 引擎与 I/O，**不可纯 golden 化**——沿用 `sandbox.smoke.ts` 的引擎集成测试
范式（parser 模式已有先例），用 fake transport 驱动端到端。

## 3. 模块拆分（TS 权威 + Dart 镜像）

| 文件 | 职责 | 测试 |
|---|---|---|
| `server/src/runtime/broker/assemble.ts` | 纯：`assembleRequest`（注入决策→取值→合并 jar→净化头）/ `processResponse`（脱敏） | golden 双跑 |
| `server/src/runtime/broker/fetch-proxy.ts` | 有态驱动：编织 assemble + transport seam + B3 redirect + B4 jar 捕获 + 限额计量 | smoke（fake transport） |
| `server/src/runtime/sandbox.ts`（改） | fetch 模式：async handler、job queue pump、await、limit 注入、执行结束 B5 钩子 | sandbox.smoke |
| `contract/golden/broker/assemble.json` | 请求拼装/响应脱敏共享向量 | — |
| `client/lib/core/...` 对应件 + `adapter_runtime.dart`（改） | Dart 镜像 | dual_run |

## 4. 请求拼装管线（§2.1 数据流，逐步对齐已合并零件）

```
ctx.fetch(url, init)
  └─ assembleRequest(url, init, view, resolver, jar):
       B1 decideInjection(url, view)
         reject     → 抛受控错误（fail-closed，url 不在 allow）
         passthrough→ 不加凭证
         inject(ref,via) → resolver.get(ref) → 据 via 拼 Cookie/Authorization
       ⊕ jar.selectCookies(url)（origin+ephemeral；同名 broker 注入 > origin > ephemeral）
       → B2 sanitizeRequestHeaders（剥 adapter 自设凭证头，纵深防御）
  └─ transport.fetch(req)  [seam]
  └─ jar.captureSetCookie(resp.setCookie, url)
  └─ B3 followRedirects（每跳 captureSetCookie；中间 Location 不外泄）
  └─ processResponse: B2 sanitizeResponseHeaders（剥 Set-Cookie/Auth 回显）
  → 交回 adapter（仅脱敏后状态/头/body）
```

**注入优先级合流**（与 B4 栅栏 2 一致）：broker 注入凭证 cookie 在 jar 输出**之上**，
即同名 `broker注入 > origin Set-Cookie > ephemeral`——B6 在 assemble 时落实这层覆盖。

## 5. 限额（ADR-009 §2.7）

- 单请求超时 10s（含重定向链总耗时按单请求计或独立计 → §8 #3）。
- 单次执行累计 30s（跨所有 ctx.fetch）。
- 单次执行 ≤20 请求（重定向跳是否计入 → §8 #3）。
- 超任一限额 → 受控错误，终止执行；已收割状态不写库（fail 不收割，避免半截状态入库）。

## 6. 安全清单（PR body，🔒 人工逐项）

- [ ] fail-closed：url 不在 allow 直接拒，凭证一律不附
- [ ] 凭证值仅核心内拼头，绝不回交 adapter；resolver 取值用完即弃
- [ ] 注入优先级 broker > origin > ephemeral 正确（不被 ephemeral 覆盖）
- [ ] 出站净化（B2）在拼头之后兜底剥 adapter 自设凭证头
- [ ] 响应脱敏（B2）+ 重定向不外泄（B3）在交回 adapter 前生效
- [ ] 限额硬执行，超限即停；fail 不触发收割
- [ ] 两端（TS campus / Dart client）语义一致；public 永不参与（红线 #2）

## 7. PR 拆分（建议拆，B6 体量大且跨引擎）

- **PR-B6a（拼装管线，纯+驱动）**：`assemble.ts` + `fetch-proxy.ts` + golden + smoke（fake transport）。安全敏感核心，独立审。
- **PR-B6b（运行时接线）**：`sandbox.ts` / `adapter_runtime.dart` 异步 handler + 限额 + B5 钩子。触引擎，沿 sandbox.smoke 范式。
- **PR-B6c（Dart 对齐 a 部分）**：拼装管线 Dart 镜像读同一 golden。

## 8. 开放点（须拍板）

| # | 议题 | 建议 |
|---|---|---|
| 1 ✅ | **ref ↔ cookie 名**（同 B5 §8 #1） | **已定路线 a（2026-06-16）**：`ref.value` 即序列化 cookie 串，inject 时**原样附加**为 Cookie 头（无需 cookie 名、无契约改动）。B6 拼装直接用 `resolver.get(ref).value`。 |
| 2 | **B6 拆分粒度** | 建议拆 a（拼装，安全核心）/ b（运行时，触引擎）/ c（Dart）；或 a+c 合一。 |
| 3 | **限额计量口径** | 重定向链耗时/跳数是否计入单请求 10s 与 ≤20 请求？建议：重定向链总耗时计入单请求 10s；每跳计入 ≤20 请求预算（防重定向放大）。 |
| 4 | **transport seam 形态** | 复用 B3 `RedirectFetcher` 思路给统一 `Transport.fetch(req)` seam；真实 transport（ADR-003）另件注入。确认。 |
| 5 | **401 处理** | ADR-009 §2.5 第 6 条：401 透传给 adapter，broker 不内联重登；执行后由 ADR-012 §2.5 生命周期按需触发。确认 B6 不拦 401。 |
