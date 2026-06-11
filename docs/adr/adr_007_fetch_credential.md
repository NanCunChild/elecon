# ADR-007：fetch 模式 —— 受限 `ctx.fetch` 与凭证注入

- **状态**：**草案（Proposed）** ⚠️ 本文触碰红线 #1（凭证）与传输/核心承重路径，按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，**必须经人工 + 安全检查清单审阅后才可接受并实现**。
- **日期**：2026-06-11
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§3.3 凭证边界、§2.2 分层）、[`adr_001_contract.md`](./adr_001_contract.md)（manifest / envelope）、[`adr_005_runtime.md`](./adr_005_runtime.md)（服务端沙箱）、[`adr_006_client_runtime.md`](./adr_006_client_runtime.md)（客户端运行时）
- **相关 issue**：[#3](https://github.com/NanCunChild/elecon/issues/3)（实现任务）、[#4](https://github.com/NanCunChild/elecon/issues/4)（iOS 2.5.2 合规）
- **适用范围**：fetch 模式 adapter 的网络出口（`ctx.fetch`）语义、可信核心的凭证注入与响应脱敏、两端（client-direct / campus-relay）执行落点。**不含** parser 模式（已由 ADR-005/006 落地）。

---

## 1. 背景（Context）

ADR-005/006 已落地 **parser 模式**：核心代取 + 脱敏 → adapter 纯解析。fetch 模式是另一档——**官方签名 adapter** 可经核心暴露的受限 `ctx.fetch` 自行发起取数（ADR-000 §3.3）。`contract/adapter-sdk/types.d.ts` 已声明 `CtxFetch.fetch`，但语义、凭证注入点、脱敏边界尚未定义。

红线 #1 要求：**凭证（值与任何等价物）永不离开可信核心**。fetch 模式把"发起请求"的控制权部分交给 adapter，因此凭证注入与响应脱敏的边界是本设计的全部重点，也是项目最高风险面（ADR-000 §5.2：核心是单点复杂度）。

---

## 2. 决策（Decision，草案）

> 以下为**待审议**的设计取向，非既定事实。每条都需安全审阅确认。

1. **`ctx.fetch` 是 fetch 模式唯一网络出口。** adapter 内无任何其他网络能力（无 XHR、无 socket、无 import 远程模块）。`ctx.fetch(url, init)` 的调用跨 isolate/wasm 边界回到宿主（客户端 Dart 核心 / 服务端 campus 中继），由**宿主**执行真实请求。

2. **凭证注入只在可信核心、由 Broker 决定，adapter 永不接触。** adapter 传入的是 URL + init；是否附加凭证、附加哪个凭证，由核心据 manifest `network.allow` 白名单匹配 + 凭证引用（如 `"session"`）决定。adapter 既拿不到凭证值，也拿不到带 token 的 URL / `Set-Cookie` / 重定向中间 token（红线 #1 的"等价物"要求）。

3. **网络出口 fail-closed：白名单之外的域名不可达（不是"可达但不注入凭证"）。** 理由：adapter 已能读到解析前的私密响应，若允许它向任意域名发请求，等于开了**数据外泄**通道。故 `network.allow` 同时是**出口闸门**（能不能连）与**注入闸门**（连了给不给凭证）两层。非白名单 → 直接拒绝并报错。

4. **响应脱敏在宿主完成后才回交 adapter。** 至少剥除：`Set-Cookie` / `Set-Cookie2`、`Authorization` / `Proxy-Authorization` 回显、`WWW-Authenticate`；**重定向由核心自行跟随**，绝不把中间跳转的 `Location`（可能含 token）暴露给 adapter；按 allowlist 策略保留的响应头白名单，其余默认丢弃。body 透传（那是 adapter 要归一化的数据）。

5. **仅官方签名 adapter 可跑 fetch 模式。** 侧载 / 社区 dev adapter 一律退化为 parser（ADR-000 §3.3、红线 #5）。trust tier 由 manifest `trustTier` + 签名校验（ADR-002，待补）裁决；非 official → 拒绝以 fetch 模式加载。

6. **fetch 模式 handler 是异步的（返回 Promise）**，与 parser 的"必须同步"相反。运行时需 pump job queue 并 await；除墙钟/内存限额（对齐 `DEFAULT_LIMITS`）外，增加**单请求与累计网络超时**。

7. **执行落点：client-direct 或 campus-relay，永不 public。** 客户端用设备本地保管的凭证直连；校外私密数据走 `server/src/campus` 校内授权中继。`server/src/public` 哑服务**永不**参与 fetch 模式凭证注入（红线 #2：公网零凭证）。envelope `source.origin` 据此标 `client-direct` / `campus-relay`。

### 2.1 凭证注入与脱敏的边界（数据流）

```
adapter(QuickJS)                 可信核心 / Broker(宿主)              校园服务器
  │  ctx.fetch(url, init) ──────▶ │
  │                               │ 1) url 匹配 network.allow？否→拒绝(fail-closed)
  │                               │ 2) 是→按凭证引用注入 cookie/token（adapter 不可见）
  │                               │ 3) 发起真实请求、自行跟随重定向 ───────▶ │
  │                               │ 4) 剥 Set-Cookie / Auth 回显 / 中间 token ◀─ │
  │  ◀── 脱敏后的 Response ─────── │
  │  归一化 → 标准 schema 产出      │
```

### 2.2 选型对比（待补充论证）

| 取向 | 取 | 舍 |
|---|---|---|
| **宿主代理 fetch + 宿主注入/脱敏（建议）** | 凭证全程在核心；adapter 只见脱敏响应；与 parser 同一信任模型 | 宿主侧脱敏需穷举 token 等价物，工程量大 |
| adapter 直接持受限 token | adapter 可灵活组装请求 | **违背红线 #1**，否决 |
| 全部退化为 parser（不做 fetch 模式） | 最安全 | 失去官方 adapter 自主取数的灵活性；多步取数/翻页难表达 |

---

## 3. 已知约束与风险（Consequences，草案）

1. **这是最高风险路径（红线 #1）。** 实现与测试**不得由 AI 独自闭环**；需安全检查清单 + 至少 1 名人工审阅（git.md §3 分级审查）。
2. **脱敏完整性是硬骨头。** token 等价物来源多（Set-Cookie、URL token、重定向链、自定义鉴权头、响应体内回显的 CSRF/token）。**默认 fail-closed**：未明确放行的头/跳转一律丢弃；需维护一份"已知泄露向量"清单并随实现增补。
3. **恶意/被攻破 adapter 的数据外泄面。** adapter 能读解析前私密响应；缓解靠：①出口白名单（§2.3 fail-closed）②仅官方签名③人工审查④（可选）出口审计日志。
4. **契约影响（红线 #6）。** 当前 manifest `requests[]`（含 `credential`）是 **parser 专用**；fetch 模式需声明"哪些出口、用哪个凭证引用"。这很可能要**扩展 manifest schema** → 属契约改动，须与 ADR-001 协调、走独立 ADR 且保持向后兼容，**不在本 ADR 内顺手改**。
5. **测试不能像 parser 那样直接 golden 双跑**（网络非确定）。取向：**录制/回放夹具**——录一次真实交互（脱敏后）成固定夹具，之后 fetch 退化为对回放响应的确定性解析，可纳入双跑；凭证注入与脱敏逻辑在**宿主**层单测（不在 QuickJS）。
6. **iOS 2.5.2（[#4]）联动。** fetch 模式让"下载的 adapter"真正发起网络请求，合规评估需与本设计一并做。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

> 安全敏感项标 🔒（人工主导、AI 仅辅助）：

- 🔒 宿主 Broker：`ctx.fetch` 代理 + 白名单匹配（uri-template）+ 凭证注入 + 响应脱敏器（含已知泄露向量清单）。客户端（Dart 核心）与服务端（`server/src/campus`）各一份，**共享同一脱敏规格**。
- 客户端运行时：`adapter_runtime.dart` 增 fetch 模式（异步 handler、job queue pump、网络超时）；`ctx.fetch` 经边界回调到 Dart 宿主。
- 服务端沙箱：`server/src/runtime/sandbox.ts` 同步增 fetch 模式 ctx。
- 契约（独立 ADR）：manifest 增 fetch 模式凭证/出口声明，向后兼容。
- 测试：录制/回放夹具机制；宿主侧脱敏/注入单测；fetch 模式双跑（基于回放）。
- 🔒 安全检查清单：随实现 PR 附"凭证零泄露"逐项自检（值/URL token/Set-Cookie/重定向/响应体回显）。
- iOS 2.5.2 合规评估（[#4]）。
