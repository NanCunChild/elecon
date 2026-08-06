# B4 实现计划 · per-execution cookie jar（两分区）

> 状态：草案（计划已经人工拍板三处开放点，见 §8）。实现属 🔒 安全敏感运行时路径，
> 按 [AGENTS.md](../../AGENTS.md) §1 **AI 不得独自闭环**，须人工 + 安全清单主导。
> 依据：[ADR-009](../adr/adr_009_fetch_credential.md) §2.4 / §2.8 ·
> [Track B 运行时计划](./track_b_imperative_runtime_plan.md) §3/§4/§5。
> 跟踪 issue：见 GitHub（挂 #17 §C / #27 依赖闸门）。

## 0. 背景与前置

B4 是 imperative requestGraph Broker（Gate A）的「执行内 cookie jar」件。解的核心缺口：多步握手中
origin 在流程中途下发的会话态——既包括标准 `Set-Cookie`，也包括 XJT 教务那种
「token 在响应 body、零 `Set-Cookie`、靠页面 JS `document.cookie` 写入」的真实缺口
（证据 `adapters_tests/XJTU/dean/pac.txt`）。

**前置已就绪**：

- 契约面 `ctx.setEphemeralCookie`（PR #34，CtxImperative 纯新增方法签名）。
- B1 `url-match` / `scope` 匹配原语 + `BrokerManifestView`（`inject-policy.ts`）。
- B2 头净化（`Set-Cookie` 从交给 adapter 的响应里剥除）。
- B3 `followRedirects` 异步 driver（多步握手常经 302）。

## 1. 范围

**含**：

- per-execution cookie jar 数据结构，**两个严格隔离分区**（ADR-009 §2.4 / Track B §3）。
- **分区 1（broker/origin 区）**：捕获 origin 下发的 `Set-Cookie`（含重定向各跳），作为
  执行内会话态 + 收割权威（B5 用）。
- **分区 2（adapter-ephemeral 区）**：`setEphemeralCookie` 写入，四重栅栏由 Broker 强制。
- 出站请求的 **Cookie 选择/拼装**（RFC 6265 发送方向匹配 + 同名优先级）。

**不含**（明确划走，避免 PR 膨胀）：

- **B5 收割桥接 → ADR-012 库**（判据 b）。本件只保证 jar 持有正确状态、ephemeral 区不进收割。
- **B6 完整请求拼装 / 真实 transport / resolver 取值**。经 seam 注入，本件用 fake。
- school-xjt `index.js` 缺口替换（属 #27，B4 合并后另开）。

## 2. 模块拆分（TS 权威 + Dart 镜像）

| 文件 | 职责 | 纯/有态 |
|---|---|---|
| `server/src/runtime/broker/cookie-match.ts` | **新原语**：RFC 6265 §5.1.3 domain-match + §5.1.4 path-match（**发送方向**）。**不复用** `url-match`（那是 uri-template 前缀语义，与 cookie 域/路径语义不同，混用会污染其锁定契约） | 纯 |
| `server/src/runtime/broker/cookie-jar.ts` | jar 类（两分区状态）+ 三个**可 golden 化的纯决策**：`decideEphemeralWrite` / `matchCookieForSend` / `selectCookies` | 纯决策 + 薄状态壳 |
| `server/src/runtime/broker/cookie-jar.smoke.ts` | golden 双跑 + 生命周期 / 隔离 / 捕获的有态单测 | — |
| `contract/golden/broker/cookie-jar.json` | 共享向量（钉两端纯决策一致） | — |
| `client/lib/core/broker/cookie_match.dart` + `cookie_jar.dart` | Dart 镜像，读同一 golden | — |
| `client/test/broker_cookie_jar_test.dart` | Dart 双跑断言 | — |

**纯/有态切分**（沿用 B3：`decideRedirect` 纯 + `followRedirects` driver）：把**判定**抽成纯函数进
golden，**状态机**（jar 增删、执行即弃）留 smoke/unit。

## 3. 四重栅栏 —— `decideEphemeralWrite(opts, view)` 精确语义

输入 `view`：复用 B1 的 `BrokerManifestView`（`{ allow: string[]; credentials?: Record<string,{scope,type}> }`）。

```
decideEphemeralWrite(opts:{domain,path?}, view) →
  | { ok: true, cookie:{name,value,domain,path} }
  | { ok: false, reason: "domain_not_passthrough" | "domain_is_credential" | "path_too_wide" }
```

- **栅栏 1（仅 passthrough origin，ADR-009 §2.4 第 143 行）**：
  1. `opts.domain` 须对**某** `network.allow` 条目的 host 做 RFC 6265 domain-match；否则 `domain_not_passthrough`。
  2. `opts.domain` **不得**对**任何** `credentials.<name>.scope` 的 host domain-match；命中即 `domain_is_credential`（**永不能写凭证域**）。
  3. `opts.path`（缺省 `/`）须为对应 allow 条目 path 的**子路径**（前缀）；越界 `path_too_wide`。
- **栅栏 2（不覆盖注入）** → 在 `selectCookies` 优先级里体现（ephemeral 最低）。
- **栅栏 3（永不收割）** → 结构隔离：收割（B5）只读分区 1，类型系统上 ephemeral 在分区 2，B5 拿不到。
- **栅栏 4（执行即弃）** → jar 实例随执行生命周期，无持久化路径（单测断言）。

**栅栏违例处置（已拍板）**：`setEphemeralCookie` 在 `decideEphemeralWrite` 返回 reject 时
**静默丢弃该写入 + `ctx.log("warn", ...)`**，**不抛错中断执行**——不给 adapter 探测栅栏边界的
异常信号。栅栏由 Broker 强制，绝不静默放宽为「接受」（同 B1「不信任上游已校验」哲学）。

**关于 `Secure` / `__Host-` 前缀（已拍板）**：本件 jar **不参与**该校验——匹配仅按
domain / path（RFC 6265 §5.1.3/§5.1.4），不校验 cookie 前缀 / Secure 属性。若未来需要，
另行评估扩面。

## 4. golden 向量设计（`cookie-jar.json`）

三组纯决策，逐条钉两端：

- **A. `decideEphemeralWrite`**（约 8 例）：passthrough 接受 / 凭证域拒（栅栏 1.2）/ 域不在 allow 拒 / path 越界拒 / path 缺省 `/` / 父域 domain-match 边界 / 大小写。
- **B. `matchCookieForSend`**（约 8 例）：domain-match 父域命中、host 不匹配不发、path 前缀命中 / 更深不发、**方向不可写反**（cookie 域更宽才发，ADR-009 §2.4 第 123 行）。
- **C. `selectCookies` 优先级**（约 5 例）：同名 broker > origin > ephemeral（栅栏 2）；多 cookie 拼接顺序；ephemeral 与 broker 不同名共存。

**有态行为**（不进 golden，进 smoke）：`Set-Cookie` 捕获默认 domain/path（RFC 6265 §5.3）、
跨重定向跳捕获、执行结束即弃、两分区隔离（写 ephemeral 不污染 broker 区收割视图）。

## 5. 与既有件的集成顺序（PR 描述须写明）

1. **捕获时机**：jar 捕获 `Set-Cookie` 必须在 **B2 响应脱敏之前**（B2 把 Set-Cookie 从交给
   adapter 的响应里剥掉；jar 在更上游吃原始响应头）。
2. **重定向**：B3 `followRedirects` 的每一跳响应都要喂给 jar（多步握手常经 302）——需在 driver
   里加一个 `onSetCookie` 回调 seam，**但不在本件改 B3**，仅声明集成契约，B6 接线。
3. **请求拼装**：最终 `Cookie` 头 = jar `selectCookies(url)` ⊕ B1 注入的凭证 cookie——合并归
   **B6**，本件只产出 `selectCookies` 的输出，不接线。

## 6. 安全清单（PR body，🔒 人工逐项）

- [ ] ephemeral 写**永不**落凭证域（栅栏 1.2 双向 domain-match 不写反）
- [ ] ephemeral 区**结构上**无法进收割（B5 只触分区 1）
- [ ] 同名优先级 ephemeral 最低，不覆盖 broker/origin（栅栏 2）
- [ ] jar 全程不回交 adapter（无任何 API 把 cookie 值 / Set-Cookie 暴露给 adapter）
- [ ] 执行即弃，无持久化路径（栅栏 4）
- [ ] 两端 golden 完全一致（domain-match 方向、path 前缀、优先级）
- [ ] 栅栏违例静默丢弃 + warn，不放宽为接受、不抛错泄漏边界

## 7. PR 拆分（已拍板：拆两个）

沿用 B1 的安全敏感小步节奏（TS 先行单独审 → Dart 对齐）：

- **PR-B4①（TS）**：`cookie-match` + `cookie-jar` + golden + smoke（server only）。
- **PR-B4②（Dart 对齐）**：镜像，读同一 golden。

## 8. 开放点拍板记录（2026-06-16）

| # | 议题 | 决定 |
|---|---|---|
| 1 | `Secure` / `__Host-` 前缀是否纳入 jar 校验 | **不纳入**，本件仅 domain/path 匹配 |
| 2 | PR 拆分 | **拆两个**（TS 先行 + Dart 对齐） |
| 3 | 栅栏违例处置 | **静默丢弃 + `ctx.log("warn")`**，不抛错 |
