# ADR-009：fetch 模式 —— 受限 `ctx.fetch` 与凭证注入

- **状态**：**草案（Proposed）** ⚠️ 本文触碰红线 #1（凭证）与传输/核心承重路径，按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，**必须经人工 + 安全检查清单审阅后才可接受并实现**。
- **日期**：2026-06-11
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§3.3 凭证边界、§2.2 分层）、[`adr_001_contract.md`](./adr_001_contract.md)（manifest / envelope）、[`adr_005_runtime.md`](./adr_005_runtime.md)（服务端沙箱）、[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（客户端运行时）
- **相关 issue**：[#3](https://github.com/NanCunChild/elecon/issues/3)（实现任务）、[#4](https://github.com/NanCunChild/elecon/issues/4)（iOS 2.5.2 合规）
- **适用范围**：fetch 模式 adapter 的网络出口（`ctx.fetch`）语义、可信核心的凭证注入与响应脱敏、两端（client-direct / campus-relay）执行落点。**不含** parser 模式（已由 ADR-005/008 落地）。

---

## 1. 背景（Context）

ADR-005/008 已落地 **parser 模式**：核心代取 + 脱敏 → adapter 纯解析。fetch 模式是另一档——**官方签名 adapter** 可经核心暴露的受限 `ctx.fetch` 自行发起取数（ADR-000 §3.3）。`contract/adapter-sdk/types.d.ts` 已声明 `CtxFetch.fetch`，但语义、凭证注入点、脱敏边界尚未定义。

红线 #1 要求：**凭证（值与任何等价物）永不离开可信核心**。fetch 模式把"发起请求"的控制权部分交给 adapter，因此凭证注入与响应脱敏的边界是本设计的全部重点，也是项目最高风险面（ADR-000 §5.2：核心是单点复杂度）。

---

## 2. 决策（Decision，草案）

> 以下为**待审议**的设计取向，非既定事实。每条都需安全审阅确认。

1. **`ctx.fetch` 是 fetch 模式唯一网络出口。** adapter 内无任何其他网络能力（无 XHR、无 socket、无 import 远程模块）。`ctx.fetch(url, init)` 的调用跨 isolate/wasm 边界回到宿主（客户端 Dart 核心 / 服务端 campus 中继），由**宿主**执行真实请求。

2. **凭证注入只在可信核心、由 Broker 决定，adapter 永不接触。** adapter 传入的是 URL + init；是否附加凭证、附加哪个凭证，由核心据 manifest `credentials` 声明（见 §2.3）+ `network.allow` 白名单匹配决定。adapter 既拿不到凭证值，也拿不到带 token 的 URL / `Set-Cookie` / 重定向中间 token（红线 #1 的"等价物"要求）。

3. **出站请求净化：宿主剥除 adapter 设置的安全相关请求头。** adapter 通过 `init.headers` 设置的 `Cookie` / `Authorization` / `Proxy-Authorization` 由宿主**无条件剥除**——凭证仅由 broker 按白名单注入，adapter 不得自行携带。其余请求头按 allowlist 保留（默认允许 `Content-Type` / `Accept` / `Accept-Language`），未放行的请求头丢弃。

4. **网络出口 fail-closed + 白名单一律注入。** `network.allow` 白名单同时是**出口闸门**与**注入闸门**，且二者不分离：命中白名单的请求**必定注入凭证**；未命中的请求**直接拒绝**。不存在"可达但不注入凭证"的中间态——adapter 不应需要访问非学校域名，若允许"可达但不注入"则 adapter 可向白名单外域名传出已读到的私密数据，等于开了数据外泄通道。

5. **响应脱敏在宿主完成后才回交 adapter。** 响应头按 **allowlist** 保留（默认：`Content-Type` / `Content-Length` / `Content-Encoding` / `Date` / `Cache-Control` / `ETag` / `Last-Modified`），**其余一律丢弃**。**重定向由核心自行跟随**，绝不把中间跳转的 `Location`（可能含 token）暴露给 adapter。**body 透传**——响应体内可能回显 CSRF token 等凭证等价物，这是**已接受的风险**：body 格式不统一（JSON / HTML / 二进制），通用脱敏不可行；缓解靠仅官方签名（§2.6）+ 人工代码审查。

6. **仅官方签名 adapter 可跑 fetch 模式。** 侧载 / 社区 dev adapter 一律退化为 parser（ADR-000 §3.3、红线 #5）。trust tier 由 manifest `trustTier` + 签名校验（ADR-002，待补）裁决；非 official → 拒绝以 fetch 模式加载。

7. **fetch 模式 handler 是异步的（返回 Promise）**，与 parser 的"必须同步"相反。运行时需 pump job queue 并 await。限额：墙钟/内存对齐 `DEFAULT_LIMITS`；**单请求超时 10s**；**累计网络超时 30s**；**单次执行最大请求数 20**（防 DDoS / 资源耗尽）。

8. **执行落点：client-direct 或 campus-relay，永不 public。** 客户端用设备本地保管的凭证直连；校外私密数据走 `server/src/campus` 校内授权中继。`server/src/public` 哑服务**永不**参与 fetch 模式凭证注入（红线 #2：公网零凭证）。envelope `source.origin` 据此标 `client-direct` / `campus-relay`。

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

### 2.3 凭证绑定的 manifest 声明（草图，待 ADR-001 协调）

fetch 模式下 adapter 不声明具体请求（那是 parser 的 `requests[]`），但仍须声明**凭证作用域**——哪些域名用哪个凭证引用。broker 据此决定注入行为。以下为初步草图，最终形态须与 ADR-001 协调并保持向后兼容（红线 #6）：

```json
{
  "mode": "fetch",
  "network": {
    "allow": ["https://jw.example.edu.cn/api/*", "https://ehall.example.edu.cn/*"]
  },
  "credentials": {
    "session": {
      "scope": ["https://jw.example.edu.cn/api/*"],
      "type": "cookie"
    },
    "ehall-token": {
      "scope": ["https://ehall.example.edu.cn/*"],
      "type": "header"
    }
  }
}
```

- `credentials.<name>.scope`：该凭证引用适用的 URL 范围（必须是 `network.allow` 的子集）。
- `credentials.<name>.type`：注入方式（`cookie` = 附加 Cookie 头；`header` = 附加 Authorization 头）。
- 一个请求 URL 匹配到哪个凭证引用由 broker 按 scope 最长前缀匹配决定。
- **校验规则**：所有 `credentials` 的 `scope` 并集必须**覆盖** `network.allow` 的全部条目（`tools/` 校验器强制）。这保证 §2.4 的"白名单一律注入"——不会出现"白名单命中但无凭证可注入"的情况。

> ⚠️ 此草图尚未纳入 `contract/manifest.schema.json`。正式扩展须走独立 ADR 且与 ADR-001 §5 协调。

### 2.4 与 HTML 源 / 多步握手 adapter 的贴合（ADR-011 / 实测 adapter 联动）

来自首批逆向 adapter（XIDIAN / XJT 通知公告，见 `adapters_tests/`）的实测，补三条本 ADR 此前未覆盖的贴合点：

1. **HTML 响应体的解析复用 [ADR-011](./adr_011_html_parser.md) 的 SDK 解析器。** fetch 模式 adapter 拿到 §2.5 透传的响应体若是 HTML，用 `elecon:html`（QuickJS 内纯 JS、两端零漂移）解析，而非各端原生——与 parser 模式同一套，不另起炉灶。

2. **多步握手依赖的中间 cookie 由宿主「单次执行 cookie jar」承载，对 adapter 不可见。** 实测 XJT 教务有 JS 反爬挑战：`GET → 读响应体里的 challengeId → POST 指纹 → origin 下发 client_id cookie → 带 cookie 再 GET`。这类"流程中途由 origin 下发、**非学生凭证**"的会话 cookie，被 §2.5"剥 `Set-Cookie` 不给 adapter"会**丢失**。贴合：**宿主在单次执行内维护一个 cookie jar，自动持久化 origin 下发的 `Set-Cookie` 并在后续 `ctx.fetch` 携带，但始终不暴露给 adapter**（红线 #1 的"等价物"要求仍满足：adapter 看不到 cookie 值）。此 jar **仅限单次执行**，不落核心凭证库、不跨执行、不经 public。

3. **反爬挑战本身定位为 official 档 + 优先服务端 public 缓存「只解一次」。** 解析内联 JS 算 answer、伪造浏览器指纹，**超出"薄归一化"**，应是 official 签名 adapter（ADR-002 official 独占 fetch），且对公开数据**优先在服务端解一次填 public 缓存**（ADR-000 §2.1），客户端不逐个绕。⚠️ 逆向期的 `verify=False`（关 TLS 校验）一类手段**禁止进标准 adapter**——TLS 必须校验（transport 不 MITM，ADR-003 §2.3）。

---

## 3. 已知约束与风险（Consequences，草案）

1. **这是最高风险路径（红线 #1）。** 实现与测试**不得由 AI 独自闭环**；需安全检查清单 + 至少 1 名人工审阅（git.md §3 分级审查）。
2. **脱敏覆盖面：请求头/响应头已闭合，响应体为已接受风险。** 出站请求头（§2.3）和响应头（§2.5）均走 allowlist、默认丢弃；重定向由核心跟随不暴露。**响应体透传是已接受的风险**（§2.5）：body 格式不统一，通用脱敏不可行；缓解靠仅官方签名 + 人工代码审查。需维护一份"已知泄露向量"清单并随实现增补。
3. **恶意/被攻破 adapter 的数据外泄面。** adapter 能读解析前私密响应；缓解靠：①出口白名单 fail-closed（§2.4）②出站请求头净化（§2.3）③仅官方签名（§2.6）④人工审查⑤（可选）出口审计日志。
4. **契约影响（红线 #6）。** fetch 模式需声明凭证作用域（§2.3 草图），涉及**扩展 manifest schema** → 属契约改动，须与 ADR-001 协调、走独立 ADR 且保持向后兼容，**不在本 ADR 内落地**。
5. **测试不能像 parser 那样直接 golden 双跑**（网络非确定）。取向：**录制/回放夹具**——录一次真实交互（脱敏后）成固定夹具，之后 fetch 退化为对回放响应的确定性解析，可纳入双跑；凭证注入与脱敏逻辑在**宿主**层单测（不在 QuickJS）。
6. **iOS 2.5.2（[#4]）联动。** fetch 模式让"下载的 adapter"真正发起网络请求，合规评估需与本设计一并做。iOS 端整体可上架形态已由 [ADR-010](./adr_010_ios_appstore.md) 定调：**首版仅 parser 模式上架，fetch 模式推迟**——本 ADR 接受并拟上 iOS 时，须按 ADR-010 §3.3 重做 2.5.2(a) 自检（仍限既有能力集）并补 5.1.1 隐私申报。
7. **单次执行 cookie jar 是新的状态面（§2.4 第 2 条）。** 多步握手所需的 per-execution cookie jar 必须严格隔离：**不落核心凭证库、不跨执行、不经 public**；其实现是宿主侧安全敏感代码，随 fetch 模式一并人工审（不得 AI 独自闭环）。jar 与 broker 的"白名单凭证注入"是两条独立路径——jar 装的是 origin 下发的非凭证会话态，broker 装的是学生凭证，二者不得混用。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

> 安全敏感项标 🔒（人工主导、AI 仅辅助）：

- 🔒 宿主 Broker：`ctx.fetch` 代理 + 白名单匹配（uri-template）+ 凭证注入（§2.3 凭证绑定）+ 出站请求头净化（§2.3）+ 响应头 allowlist 脱敏（§2.5）。客户端（Dart 核心）与服务端（`server/src/campus`）各一份，**共享同一净化/脱敏规格**。
- 客户端运行时：`adapter_runtime.dart` 增 fetch 模式（异步 handler、job queue pump、网络/并发限额 §2.7）；`ctx.fetch` 经边界回调到 Dart 宿主。
- 服务端沙箱：`server/src/runtime/sandbox.ts` 同步增 fetch 模式 ctx。
- 契约（独立 ADR）：manifest 增 `credentials` 声明（§2.3 草图），与 ADR-001 协调，向后兼容。
- 测试：录制/回放夹具机制；宿主侧净化/脱敏/注入单测；fetch 模式双跑（基于回放）。
- 🔒 安全检查清单：随实现 PR 附"凭证零泄露"逐项自检（出站请求头/响应头/重定向/body 已接受风险确认）。
- iOS 2.5.2 合规评估（[#4]）。
