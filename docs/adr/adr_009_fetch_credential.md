# ADR-009：imperative requestGraph —— 受限 `ctx.fetch` 与凭证注入

> **术语（ADR-022）**：旧称「fetch 模式」= 今 **imperative requestGraph**；旧称「parser 模式」= 今 **declarative requestGraph**。本文机制章节可保留历史「fetch 模式」一句，现行契约键为 per-capability `requestGraph`。

- **状态**：已接受（Accepted） 本文触碰红线 #1（凭证）与传输/核心承重路径，按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，经人工 review（PR #23）+ 安全检查清单审阅后接受。
- **日期**：2026-06-11（修订历史见末尾 [§附录 A](#附录-a修订记录)）
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§3.3 凭证边界、§2.2 分层）、[`adr_001_contract.md`](./adr_001_contract.md)（manifest / envelope）、[`adr_005_runtime.md`](./adr_005_runtime.md)（服务端沙箱）、[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（客户端运行时）
- **相关 issue**：[#3](https://github.com/NanCunChild/elecon/issues/3)（实现任务）、[#4](https://github.com/NanCunChild/elecon/issues/4)（iOS 2.5.2 合规）
- **适用范围**：imperative capability 的网络出口（`ctx.fetch`）语义、可信核心的凭证注入与响应脱敏、两端（client-direct / campus-relay）执行落点。**不含** declarative requestGraph（已由 ADR-005/008 落地）。

---

## 1. 背景（Context）

ADR-005/008 已落地 **declarative requestGraph**（旧称 parser 模式）：核心代取 + 脱敏 → adapter 纯解析。imperative（旧称 fetch 模式）是另一档——**官方签名 adapter** 可经核心暴露的受限 `ctx.fetch` 自行发起取数（ADR-000 §3.3）。`contract/adapter-sdk/types.d.ts` 已声明 `CtxImperative.fetch`，但语义、凭证注入点、脱敏边界尚未定义。

红线 #1 要求：**凭证（值与任何等价物）永不离开可信核心**。imperative 把"发起请求"的控制权部分交给 adapter，因此凭证注入与响应脱敏的边界是本设计的全部重点，也是项目最高风险面（ADR-000 §5.2：核心是单点复杂度）。

---

## 2. 决策（Decision，草案）

> 以下为**待审议**的设计取向，非既定事实。每条都需安全审阅确认。

1. **`ctx.fetch` 是 imperative requestGraph 唯一网络出口。** adapter 内无任何其他网络能力（无 XHR、无 socket、无 import 远程模块）。`ctx.fetch(url, init)` 的调用跨 isolate/wasm 边界回到宿主（客户端 Dart 核心 / 服务端 campus 中继），由**宿主**执行真实请求。

2. **凭证注入只在可信核心、由 Broker 决定，adapter 永不接触。** adapter 传入的是 URL + init；是否附加凭证、附加哪个凭证，由核心据 manifest `credentials` 声明（见 §2.3）+ `network.allow` 白名单匹配决定。adapter 既拿不到凭证值，也拿不到带 token 的 URL / `Set-Cookie` / 重定向中间 token（红线 #1 的"等价物"要求）。

3. **出站请求净化：宿主剥除 adapter 设置的安全相关请求头。** adapter 通过 `init.headers` 设置的 `Cookie` / `Authorization` / `Proxy-Authorization` 由宿主**无条件剥除**——凭证仅由 broker 按白名单注入，adapter 不得自行携带。其余请求头按 allowlist 保留（默认允许 `Content-Type` / `Accept` / `Accept-Language`），未放行的请求头丢弃。**`init.headers.Cookie` 的无条件剥除规则不因 §2.4 修订而松动**：adapter 永不能经 `init.headers` 自带 cookie/会话态；唯一受控写回路径是 §2.4 的专用窄 API（写入 ephemeral 分区、仅 passthrough origin），与本规则正交。

4. **网络出口 fail-closed；白名单分「注入」与「仅可达」两类。** `network.allow` 白名单是唯一出口闸门——未命中的请求**直接拒绝**（fail-closed，堵数据外泄）。白名单内的条目分两类：
   - **注入（inject）**：URL 命中某 `credentials.<name>.scope` → broker 自动附加对应凭证。这是默认/主路径。
   - **仅可达（passthrough）**：URL 在 `network.allow` 内但**不命中任何** `credentials.scope` → 请求放行但**不注入任何凭证**。典型场景：反爬挑战端点（尚未通过挑战、带凭证反而暴露）、公开 CDN 资源、OAuth 中间端点等。

   **安全保证不变**：出口仍 fail-closed（白名单外不可达）；数据外泄通道仍被封堵（passthrough URL 也必须在 `network.allow` 内，adapter 无法任意外传）。区别仅在于：不再强制"可达即注入"——这解开了 imperative 多步握手中"挑战端点不应携带凭证"的死结。

5. **响应脱敏在宿主完成后才回交 adapter。** 响应头按 **allowlist** 保留（默认：`Content-Type` / `Content-Length` / `Content-Encoding` / `Date` / `Cache-Control` / `ETag` / `Last-Modified`），**其余一律丢弃**。**重定向由核心自行跟随**（最多 **5 跳**，每跳目标必须仍在 `network.allow` 内，否则停止并返回最后一个合法响应），绝不把中间跳转的 `Location`（可能含 token）暴露给 adapter。**body 透传**——响应体内可能回显 CSRF token 等凭证等价物，这是**已接受的风险**：body 格式不统一（JSON / HTML / 二进制），通用脱敏不可行；缓解靠仅官方签名（§2.6）+ 人工代码审查 + **后续计划的 pattern-based 后置审计**（对 adapter 产出做 token-pattern 扫描告警，非阻断）。

6. **HTTP 错误响应（含 401）透传给 adapter，imperative adapter 自行处理。** broker 完成脱敏后，**原始 HTTP status code**（包括 401/403/5xx）直接回交 adapter——adapter 可据此决定重试、回退、或返回错误。broker **不拦截 401 做自动重登**（那是 ADR-012 §2.5 生命周期的职责，由核心在 adapter 执行结束后按需触发，不在单次 `ctx.fetch` 调用内联）。declarative 的 401 处理待定（核心代取时遇到 401 的策略由 declarative 设计另行定义）。

7. **仅官方签名 adapter 可跑 imperative requestGraph。** 侧载 adapter 每个 capability 强制 declarative（ADR-000 §3.3、红线 #5 / ADR-022）。信任档由**核心验签裁定**（ADR-002 §2.2），不信任 manifest 自报的 `trustTier`；非 official → `ctx.fetch` 调用被宿主边界拒绝（ADR-002 §2.6 结构化权限错误），永不触达凭证注入。

8. **imperative handler 是异步的（返回 Promise）**，与 declarative 的"必须同步"相反。运行时需 pump job queue 并 await。限额（**数值为临时占位，2026-06-14：尚无实测依据，待真实多步握手 adapter 上线后校准——多步反爬流程可能吃掉请求数预算，需实践验证 20 是否够用**）：墙钟/内存对齐 `DEFAULT_LIMITS`；**单请求超时 ~10s**；**累计网络超时 ~30s**；**单次执行最大请求数 ~20**（防 DDoS / 资源耗尽）。**单次响应 body 大小设宿主侧独立上限**（rev-4 修订，见 §2.9——**推翻 rev-2 的"不设独立上限、靠 QuickJS OOM 兜底"**：宿主在字节进 QuickJS 之前已把整个 body 读进宿主堆，OOM 覆盖不到宿主 transport 阶段）。最终数值随实测在落地清单的运行时 PR 内固定。**校准承诺**：首个 imperative adapter 上线前，须以真实多步握手流程（至少覆盖一个含反爬挑战的学校）实测校准上述占位值（含 §2.9 body 上限），并更新本节为正式数值。

9. **执行落点：client-direct 或 campus-relay，永不 public。** 客户端用设备本地保管的凭证直连；校外私密数据走 `server/src/campus` 校内授权中继。`server/src/public` 哑服务**永不**参与 imperative 凭证注入（红线 #2：公网零凭证）。envelope `source.origin` 据此标 `client-direct` / `campus-relay`。

10. **宿主主动取消 in-flight transport 请求（rev-4 新增，见 §2.9）。** 单请求超时 / 累计网络超时 / 请求数超限 / body 超限 / 执行级 fatal 任一触发时，宿主**主动中止**对应的上游请求（不只是竞速丢弃 Promise），并取消该次执行所有仍在飞行的 transport 请求。这封堵 rev-2 的隐患——"超时只是 race，上游请求未必被取消"（[`adr_014`](./adr_014_client_host_fn.md) §4.7 已列为后续项，本修订认领）。

### 2.1 凭证注入与脱敏的边界（数据流）

```
adapter(QuickJS)                 可信核心 / Broker(宿主)              校园服务器
  │  ctx.fetch(url, init) ──────▶ │
  │                               │ 1) url 匹配 network.allow？否→拒绝(fail-closed)
  │                               │ 2) url 命中 credentials.scope？
  │                               │    是→注入对应凭证（adapter 不可见）
  │                               │    否→passthrough（不注入，仅放行）
  │                               │ 3) 发起真实请求、自行跟随重定向（max 5 跳，每跳须仍在 allow 内）──▶ │
  │                               │ 4) 剥 Set-Cookie → per-execution jar（adapter 不可见）◀─ │
  │                               │ 5) 剥 Auth 回显 / 响应头 allowlist 过滤
  │  ◀── 脱敏后的 Response ─────── │
  │  （含原始 status code，如 401） │
  │  归一化 → 标准 schema 产出      │
```

> **执行内 ephemeral cookie（§2.4 修订，2026-06-15）**：上图步骤 4 的 per-execution jar 之外，adapter 可经窄 API 把**仅本次执行有效**的 cookie 写入 jar 的独立 ephemeral 分区（仅限 passthrough origin）。该分区与 broker 注入分区严格隔离、不参与步骤的凭证注入、不参与执行结束的收割。语义见 §2.4。

### 2.2 选型对比（待补充论证）

| 取向 | 取 | 舍 |
|---|---|---|
| **宿主代理 fetch + 宿主注入/脱敏（建议）** | 凭证全程在核心；adapter 只见脱敏响应；与 declarative 同一信任模型 | 宿主侧脱敏需穷举 token 等价物，工程量大 |
| adapter 直接持受限 token | adapter 可灵活组装请求 | **违背红线 #1**，否决 |
| 全部退化为 declarative（不做 imperative） | 最安全 | 失去官方 adapter 自主取数的灵活性；多步取数/翻页难表达 |

### 2.3 凭证绑定的 manifest 声明（草图，待 ADR-001 协调）

imperative 下 adapter 不声明具体请求（那是 declarative 的 `requests[]`），但仍须声明**凭证作用域**——哪些域名用哪个凭证引用。broker 据此决定注入行为。以下为初步草图，最终形态须与 ADR-001 协调并保持向后兼容（红线 #6）。（注：旧顶层 `mode: "fetch"` 已由 ADR-022 抹除；现行为 per-capability `requestGraph: "imperative"`。）

```json
{
  "network": {
    "allow": [
      "https://jw.example.edu.cn/api/*",
      "https://ehall.example.edu.cn/*",
      "https://captcha.example.edu.cn/challenge/*"
    ]
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
- 一个请求 URL 匹配到哪个凭证引用由 broker 按 scope 最长前缀匹配决定。**消歧规则**：① 严格最长前缀胜出（覆盖范围越窄 = 越精确 = 优先级越高）；② 若两条 scope 前缀长度**完全相同**（语义重叠），manifest 校验器**拒绝通过**（红线 #6 校验阶段捕获，而非运行时再判）——禁止歧义凭证绑定。
- **`network.allow` 中未被任何 `credentials.scope` 覆盖的条目 = passthrough**（可达但不注入凭证）。上例中 `https://captcha.example.edu.cn/challenge/*` 不在任何 scope 内 → 请求放行但不带凭证，适用于反爬挑战等场景。
- **校验规则**：① 所有 `credentials.scope` 必须是 `network.allow` 的**子集**（`tools/` 校验器强制：不能声明注入一个连出口都不允许的 URL）；② passthrough 条目**无需被 scope 覆盖**——这是合法的"声明但不注入"。

> 此草图的**正式 schema 扩展已拆为独立 ADR**：见 [`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md)（草案），它把本 §2.3 草图落为 `contract/manifest.schema.json` 的可选顶层 `credentials` 块、与 ADR-001 §5 协调、向后兼容（红线 #6），并定义 `tools/` 校验器的静态规则。本 §2.3 与 ADR-013 的匹配规格（scope ⊆ network.allow、最长前缀消歧）须共享同一实现。

### 2.4 与 HTML 源 / 多步握手 adapter 的贴合（ADR-011 / 实测 adapter 联动）

来自首批逆向 adapter（XIDIAN / XJT 通知公告）的本地 spike 实测，补三条本 ADR 此前未覆盖的贴合点：

1. **HTML 响应体的解析复用 [ADR-011](./adr_011_html_parser.md) 的 SDK 解析器。** imperative adapter 拿到 §2.5 透传的响应体若是 HTML，用 `elecon:html`（QuickJS 内纯 JS、两端零漂移）解析，而非各端原生——与 declarative 同一套，不另起炉灶。

2. **多步握手依赖的中间 cookie 由宿主「单次执行 cookie jar」承载，对 adapter 不可见。** 实测 XJT 教务有 JS 反爬挑战：`GET → 读响应体里的 challengeId → POST 指纹 → origin 下发 client_id cookie → 带 cookie 再 GET`。这类"流程中途由 origin 下发"的会话 cookie，被 §2.5"剥 `Set-Cookie` 不给 adapter"会**丢失**。贴合：**宿主在单次执行内维护一个 cookie jar，自动持久化 origin 下发的 `Set-Cookie` 并在后续 `ctx.fetch` 携带，但始终不暴露给 adapter**（红线 #1 的"等价物"要求仍满足：adapter 看不到 cookie 值）。此 jar **仅限单次执行**，不跨执行、不经 public。

**耐久 session 的收割桥接（2026-06-14 增，解"jar 不持久化下的有效性"问题）。** 分类口径**不是"origin 下发 vs 学生凭证"，而是"跨执行是否仍有用"**：

- **执行内瞬态**（挑战 nonce、握手中途的 `client_id` 等）：用完即弃，jar 丢掉**无损**——它本就只在这一次握手内有意义。
- **跨执行耐久 session**（真正登录后的会话 cookie，带 `Max-Age`/`Expires`、有有效期、值得复用）：**不应随 jar 丢弃**。执行结束时，**核心从 jar 中收割耐久 cookie 存入 ADR-012 凭证库**（与 [`adr_012`](./adr_012_credential_store.md) §2.2 的 WebView 登录"收割 session"是**同一动作**，触发点从登录页扩展到 imperative 握手结束），带 `expiresAt`、走生命周期、401 时按 §2.6 / ADR-012 §2.5 刷新。adapter 全程仍看不到值。

**收割判据（判据 b，显式且可审计）**：**只收割 manifest `credentials.<name>` 显式声明了 ref 的那些 cookie**，其余一律按瞬态丢弃。不靠 cookie 属性启发式（判据 a）猜"哪些算耐久"——以已验签 manifest 的显式声明为准，与 [`adr_013`](./adr_013_manifest_credentials.md) 的 `credentials` 块对齐。

**匹配算法（从 jar 中选择收割目标）**：遍历 manifest 中所有 `credentials.<name>` 且 `type: "cookie"` 的条目；对每个条目，取其 `scope` 中**每条** URL 前缀解析出 `(scheme, host, pathPrefix)`，在 jar 中按 **RFC 6265 标准匹配方向**筛选——即"该 cookie 是否会被发往 scope 内的 URL"：
  - **域匹配（RFC 6265 §5.1.3）**：scope host **domain-match** 该 cookie 的 `Domain`——即 cookie `Domain` 等于 scope host 或为其**父域**（cookie 的作用域等于或更宽）。**方向不可写反**：是 scope host 落在 cookie 域内，不是 cookie 域落在 scope host 内（后者会漏掉以父域下发的 session cookie）。
  - **路径匹配（RFC 6265 §5.1.4）**：cookie 的 `Path` 是 scope `pathPrefix` 的**前缀**（cookie 适用于 scope 路径或更宽）；cookie path 比 scope 更深则不会发往 scope，不收割。
  - **`Secure` / scheme**：scope 为 `https` 时 `Secure` cookie 正常纳入；非 https scope 不应出现（C4 警告）。

  **匹配到的 cookie 整体（name=value 对集合）作为该 credential ref 的值写入 `CredentialEntry.value`**（加密落盘）。若 jar 中无命中 cookie 则不写入（该 ref 无收割产出，不是错误——可能本次执行未走登录流程）。

**jar cookie 与 broker 注入的优先级**：当 broker 据 credential ref 预注入了 cookie A，且 origin 在本次执行的后续响应中 `Set-Cookie` 了同名 cookie A（值不同），后续 `ctx.fetch` 请求中**以 jar 中 origin 最新下发的值为准**（origin 可能刚刷新了 session）。但**收割入库时，仍以 jar 中的最终状态为权威**——即 origin 的最新值覆盖预注入值。broker 下次执行时从库中取到的就是 origin 刷新后的值。这确保 session 轮换场景下凭证库不会持有过期值。

这样：①有效性问题消失（耐久 session 进库可复用）；②红线 #1 不破（收割在核心、adapter 不可见）；③jar 回归纯草稿纸。**未被任何 ref 声明的 cookie 永不进库**——封死"adapter 诱导 origin 下发任意 cookie 持久化到核心"的面。此桥接是宿主侧安全敏感代码，随 imperative 一并人工审（不得 AI 独自闭环）。

**执行内 ephemeral cookie 写回通道（2026-06-15 修订，🔒 待人工复核）。** 实测暴露一类本 ADR 此前未覆盖的会话态：**origin 不经 `Set-Cookie`、而把会话 token 放在响应 body、由页面 JS 自行 `document.cookie` 写入**。证据见 `adapters_tests/XJTU/dean/pac.txt`：XJT 教务挑战页 JS `document.cookie = "client_id=" + data.client_id`，`client_id` 取自 `POST /dynamic_challenge` 的响应 JSON body，全程**零 `Set-Cookie`**。此时 per-execution jar（只捕获 `Set-Cookie`）抓不到、§2.3 又剥除 adapter 自设 Cookie 头 → 多步握手在第二个 GET 处断裂。

**贴合（窄通道，不松动任何凭证边界）**：jar 内划出与 broker 注入分区**严格隔离**的 **ephemeral 分区**；adapter 经专用窄 API 写入：

```ts
// CtxImperative 增（仅 imperative 生效；契约改动见 §4，红线 #6，纯新增向后兼容）
setEphemeralCookie(name: string, value: string, opts: { domain: string; path?: string }): void;
```

**Broker 强制的四重栅栏（缺一即拒——静默丢弃该写入 + `ctx.log("warn")`，不抛错、不给 adapter 探测栅栏边界的异常信号）**：
1. **仅 passthrough origin**：`opts.domain` 必须落在某 `network.allow` 条目内、且**不**落在任何 `credentials.<name>.scope` 内——永不能写到凭证域，杜绝伪造/覆盖真实凭证。匹配算法：取 `network.allow` 条目的 host 部分，对 `opts.domain` 做 **RFC 6265 §5.1.3 domain-match**（与 §2.4 收割匹配算法方向一致）。`opts.path`（若提供）须为对应 `network.allow` 条目 path 部分的**子路径**（前缀匹配）——不允许 adapter 写出比白名单声明更宽的 cookie 路径；缺省时默认 `/`（仅在该 allow 条目本身为 `/` 或未限定 path 时合法）。
2. **不覆盖 broker 注入**：ephemeral 分区在请求拼装时优先级**低于** broker 注入分区与 origin `Set-Cookie`；同名以后两者为准。
3. **永不收割**：ephemeral 分区**不参与** §2.4 收割桥接（判据 b 只认 manifest `credentials` 声明 ref + origin `Set-Cookie` 状态），绝不进 ADR-012 库。
4. **执行即弃**：ephemeral 分区随 per-execution jar 整体在执行结束时丢弃，不跨执行、不持久化到任何存储。这是栅栏 3 的自然推论，但作为独立约束显式声明——即使未来收割逻辑变更，ephemeral 的生命周期上限仍为单次执行。

**为何不破红线 #1**：`client_id` 一类是 **origin 的反爬会话 token，非学生凭证**；adapter 经 §2.5 body 透传**本就能读到该值**，允许其写回**同源 passthrough** cookie，不新增任何超出 body 透传既有面的外泄面。`max-age` 等"看似耐久"属性不改变定性——收割只认判据 b，未声明即瞬态。此通道是宿主侧安全敏感代码，随 imperative 一并人工审（不得 AI 独自闭环）。

3. **反爬挑战由 imperative adapter 处理（official 独占）。** 解析内联 JS 算 answer、伪造浏览器指纹，**超出"薄归一化"**，天然属于 imperative adapter 的职责（ADR-002 official 独占 imperative）。典型流程：adapter `ctx.fetch` 挑战端点（passthrough，不注入凭证）→ 解析 challenge → `ctx.fetch` 提交 answer → per-execution jar 自动带上 origin 下发的 cookie → 后续请求正常走凭证注入。对公开数据，campus-relay 侧的 adapter 执行结果可经**服务端 public 缓存**（ADR-000 §2.1）分发——public 服务器本身**不执行 adapter 也不持凭证**（红线 #2），只缓存已归一化的产出。逆向期的 `verify=False`（关 TLS 校验）一类手段**禁止进标准 adapter**——TLS 必须校验（transport 不 MITM，ADR-003 §2.3）。

### 2.9 宿主侧响应 body 上限 + transport 取消语义（rev-4，已复核并接受）

> **本节是对 rev-2 决策点 8 的已接受修订。** 触传输 / 核心承重路径（红线 #1 数据流 + 资源耗尽面），按 AGENTS.md §1 **AI 不得独自闭环**：本节由 AI 起草（跟踪 #79 P0-3），已完成人工复核并接受；后续实现仍须人工 + 安全清单复核。

**要改什么（rev-2 的洞）。** rev-2 决策点 8 写「单次响应 body 大小不另设独立上限——由 `DEFAULT_LIMITS` 的整体内存上限兜底（响应体载入 QuickJS 堆，超限触发 OOM）」。此论断**在宿主 transport 阶段不成立**：实测实现（`server/src/runtime/transport/direct.ts` 的 `resp.text()`、`client/lib/core/transport/direct.dart` 的 `_collectBytes`）**先把整个响应体读进宿主（Node undici / Dart HttpClient）堆**，再 marshal 进 QuickJS。QuickJS 的内存上限只界定 QuickJS 堆，作用在**已暴露之后**——一个恶意/被劫持的 origin（或指向大资源的重定向）返回数 GB body 可在 body 进 QuickJS 之前耗尽宿主进程内存（乃至被 OS OOM-killer 杀死整个核心进程）。QuickJS OOM 兜底在这条链上是**下游**，护不住上游。

**决策 1：宿主 transport 层强制单响应 body 字节上限（fail-closed）。** 两级机制，**流式读取上限为权威闸门**：

- **`Content-Length` 预检（早退优化，非权威）**：响应头声明的 `Content-Length` 超上限 → 读 body 之前即中止、判 `body_limit`。`Content-Length` 可缺省或撒谎，故仅作快速早退，不作唯一依据。
- **流式累计上限（权威）**：边流式读取边累计字节，累计超上限即**中止读取 + 取消上游请求**（决策 2）、判 `body_limit`。这是真正的护栏——无论 `Content-Length` 是否可信。
- 上限**独立于** `DEFAULT_LIMITS` 的 QuickJS 内存上限，且应显著小于它（body 须先容于宿主堆、再容于 QuickJS 堆）。**占位值 ~8 MiB / 单响应**（与决策点 8 其余占位同性质，纳入 §2.8 校准承诺——首个含大响应/分页的真实 adapter 上线前实测校准）。
- 上限**每响应各自计**（不累加跨请求），超限即终止本次执行；**fail 不收割**（与既有 `fetch_limit` 家族一致）。失败原因词表增 `body_limit`（运行时层面，不进契约 error.kind——与既有 `SandboxFailureReason` / `AdapterFailureReason` 惯例一致）。

**决策 2：`Transport.fetch` 增取消令牌，宿主在限额/fatal 时主动中止上游。** 现状「超时只是 race / timeout，上游请求未必被取消」（决策点 10 + [`adr_014`](./adr_014_client_host_fn.md) §4.7）。修订：

- `Transport.fetch` 接口增 `AbortSignal`（TS）/ cancel token（Dart）参数——**传输 seam 契约面变更**，两端 `DirectTransport` 与所有调用方同步；因 `Transport` 是宿主内部接口（非 `contract/` 契约），不涉红线 #6，但仍属核心承重面，随实现人工审。
- 触发主动取消的事件：单请求超时、累计网络超时、请求数超限、**body 超限（决策 1）**、执行级 fatal。任一发生 → abort 对应上游请求，并取消该次执行**所有 in-flight** transport 请求（TS `AbortController`；Dart 经 `HttpClientRequest` 生命周期 / `close`）。
- 安全动机：不仅省资源，更防"执行已判失败、上游请求却仍在飞、其携带的注入凭证仍在发往 origin"的窗口——主动取消收窄凭证在途暴露时间。

**不变量不变。** 本节只加**宿主侧资源闸门 + 取消**，不触碰凭证注入 / 脱敏 / 白名单 fail-closed 语义（§2.1–§2.6）。body 上限是**拒绝服务面的收窄**，不改变"body 透传是已接受风险"（§2.5）——它限的是体量，不是内容脱敏。

---

## 3. 已知约束与风险（Consequences，草案）

1. **这是最高风险路径（红线 #1）。** 实现与测试**不得由 AI 独自闭环**；需安全检查清单 + 至少 1 名人工审阅（git.md §3 分级审查）。
2. **脱敏覆盖面：请求头/响应头已闭合，响应体为已接受风险 + 后置审计计划。** 出站请求头（§2.3）和响应头（§2.5）均走 allowlist、默认丢弃；重定向由核心跟随不暴露（max 5 跳 + 每跳白名单校验）。**响应体透传是已接受的风险**（§2.5）：body 格式不统一，通用脱敏不可行；缓解靠仅官方签名 + 人工代码审查。**后续计划 pattern-based 后置审计**：对 adapter 的最终产出（归一化后的 envelope）做 token-pattern 扫描（正则匹配已知凭证格式），**告警但不阻断**——发现可疑泄露后触发人工复查，不影响正常执行。需维护一份"已知泄露向量"清单并随实现增补。
3. **恶意/被攻破 adapter 的数据外泄面。** adapter 能读解析前私密响应；缓解靠：①出口白名单 fail-closed（§2.4）②出站请求头净化（§2.3）③仅官方签名（§2.6）④人工审查⑤（可选）出口审计日志。
4. **请求 body 外泄向量（已接受风险）。** adapter 控制 `ctx.fetch` 的请求 body（POST/PUT），理论上可将从私密响应中解析到的敏感数据编码进请求体，发往 passthrough 端点（该端点在白名单内但不注入凭证）。**缓解**：① passthrough 端点仍须声明于 `network.allow`，**由签名覆盖、CI 静态审计、人工 review 三重把关**——不可能偷偷加入一个 attacker-controlled 的 passthrough URL；② 仅官方签名 adapter 可跑 imperative（§2.6），代码审查覆盖所有出站路径；③ 后续 pattern-based 后置审计可扩展至检查**出站请求 body** 中的 token 模式。此向量与响应 body 透传（§3.2）对称——均是"仅官方签名 + code review"兜底的已接受残余风险。
5. **契约影响（红线 #6）。** imperative 需声明凭证作用域（§2.3 草图），涉及**扩展 manifest schema** → 属契约改动，须与 ADR-001 协调、走独立 ADR 且保持向后兼容，**不在本 ADR 内落地**。
6. **测试不能像 declarative 那样直接 golden 双跑**（网络非确定）。取向：**录制/回放夹具**——录一次真实交互（脱敏后）成固定夹具，之后 imperative 退化为对回放响应的确定性解析，可纳入双跑；凭证注入与脱敏逻辑在**宿主**层单测（不在 QuickJS）。
7. **iOS 2.5.2（[#4]）联动。** imperative 让"下载的 adapter"真正发起网络请求，合规评估需与本设计一并做。iOS 端整体可上架形态已由 [ADR-010](./adr_010_ios_appstore.md) 定调：**首版仅 declarative 上架，imperative 推迟**——本 ADR 接受并拟上 iOS 时，须按 ADR-010 §3.3 重做 2.5.2(a) 自检（仍限既有能力集）并补 5.1.1 隐私申报。
8. **单次执行 cookie jar 是新的状态面（§2.4 第 2 条）。** per-execution cookie jar 本身**仅限单次执行、不跨执行、不经 public**；其实现是宿主侧安全敏感代码，随 imperative 一并人工审（不得 AI 独自闭环）。**例外（2026-06-14）**：执行结束时，**仅 manifest `credentials` 显式声明了 ref 的耐久 cookie** 被核心收割进 ADR-012 凭证库（§2.4 收割桥接，判据 b）——这是受控、可审计的跨执行持久化，不是 jar 自身持久化。未被声明的 cookie 一律随 jar 丢弃，绝不进库。jar 的"瞬态搬运"与 broker 的"白名单凭证注入"仍是两条独立路径，注入路径只认凭证库内的条目。
9. **ephemeral 写回通道是新增的 adapter→jar 写入面（§2.4 修订，2026-06-15）。** 此前 adapter 对 jar 只读不可写；新通道开了一条受控写入路径，须确保四重栅栏（仅 passthrough origin / 不覆盖凭证 / 永不收割 / 执行即弃）由 **Broker 强制**而非依赖 adapter 自律——栅栏校验是宿主侧安全敏感代码，随 B4 人工审。**残余风险**：adapter 可借此向同源 passthrough 端点构造任意 cookie，但因 ① 仅 passthrough（无凭证可冒充）② 该端点本就在 `network.allow`、受签名 + CI + review 三重把关（同 §3.4 请求 body 向量），此面不超出既有已接受残余风险。**抓包前置**：本通道之所以需要，依据 `adapters_tests/XJTU/dean/pac.txt` 实测（零 Set-Cookie / body-token）；若未来站点改为标准 `Set-Cookie`，现有 jar 即可，本通道对该站点不激活。

---

## 4. 落地清单（按已接受 ADR 拆成可审查的小 PR，落地后删除）

> 安全敏感项标：

- 宿主 Broker：`ctx.fetch` 代理 + 白名单匹配（uri-template）+ **inject/passthrough 分流** + 凭证注入（§2.3 凭证绑定）+ 出站请求头净化（§2.3）+ 响应头 allowlist 脱敏（§2.5）+ **重定向跳数限制 + 每跳白名单校验**。客户端（Dart 核心）与服务端（`server/src/campus`）各一份，**共享同一净化/脱敏规格**。
- **per-execution cookie jar**：仅限单次执行、不落核心凭证库、不跨执行、scope 受 network.allow 约束；与 broker 凭证注入严格分离。**两分区**：broker 注入区（凭证背书、adapter 只读）+ ephemeral 区（§2.4 修订，adapter 经 `setEphemeralCookie` 写、仅 passthrough、不收割）。
- **契约改动（§2.4 修订连带，红线 #6）**：`contract/adapter-sdk/types.d.ts` 的 `CtxImperative` 增 `setEphemeralCookie(name, value, { domain, path? })`，**纯新增、向后兼容**；须待本修订经人工 + 安全清单复核后随 B4 一并落地（属 Gate B，不阻塞 Gate A 的 broker 核心工作）。
- 客户端运行时：`adapter_runtime.dart` 增 imperative（异步 handler、job queue pump、网络/并发限额 §2.8）；`ctx.fetch` 经边界回调到 Dart 宿主。
- 服务端沙箱：`server/src/runtime/sandbox.ts` 同步增 imperative ctx。
- **宿主 body 上限 + transport 取消（§2.9，rev-4，已复核并接受，#79 P0-3）**：两端 `DirectTransport` 增流式 body 字节上限（`Content-Length` 预检 + 累计上限，超限 `body_limit` + 取消上游）；`Transport.fetch` 接口增 `AbortSignal`/cancel token；运行时在限额/fatal 时主动取消所有 in-flight 请求。附资源耗尽负例测试（超上限 body → 中止、上游被 abort、fail 不收割）。
- ~~**契约 schema（独立 issue + PR）**：manifest 增 `credentials` 声明（§2.3 草图）~~ **已落地**：[`adr_013`](./adr_013_manifest_credentials.md) + PR #22（manifest.schema.json 增可选 `credentials` 块 + tools 校验器 C6–C9），向后兼容。
- 测试：录制/回放夹具机制；宿主侧净化/脱敏/注入单测；imperative 双跑（基于回放）。
- **pattern-based 后置审计**（后续，非阻塞）：对 adapter 产出做 token-pattern 扫描，告警不阻断。**时间线**：**初版 token-pattern 清单建议随首个 imperative adapter PR 一并落地**（彼时已有真实凭证格式可建清单），不阻塞本 ADR 接受；清单随实现增补。
- 安全检查清单：随实现 PR 附"凭证零泄露"逐项自检（出站请求头/响应头/重定向/body 已接受风险确认 + passthrough 不带凭证确认）。
- iOS 2.5.2 合规评估（[#4]）。

---

## 附录 A：修订记录

| 日期 | 标识 | 变更摘要 |
|---|---|---|
| 2026-06-11 | 初稿 | 首版草案提交 review |
| 2026-06-13 | rev-1 | §2 第 4 条改白名单分"注入/仅可达"两类；增重定向跳数限制 + 每跳白名单校验；增 §2 第 6 条 401 透传行为；§2.6/§2.4 对齐 ADR-002 修订；credentials schema 校验规则同步 |
| 2026-06-13 | rev-1b | §2.3 增 scope 重叠消歧规则（最长前缀胜出、等长拒绝）；§3 增第 4 条请求 body 外泄向量声明 |
| 2026-06-14 | rev-2 | §2.8 限额数值标注临时占位（待实测校准）；§2.4 增执行结束耐久 cookie 收割进凭证库桥接（判据 = manifest 声明的 credential ref，与 ADR-013 对齐）；§2.3 草图正式拆出 ADR-013 |
| 2026-06-14 | rev-2b（PR #23 review 跟进）| §2.4 补 cookie 收割匹配算法（RFC 6265 §5.1.3/5.1.4 域/路径匹配方向，修正初稿写反的方向）+ jar/broker 同名 cookie 优先级（origin 最新值为准）；§2.8 加校准硬承诺；§4 标 ADR-013 已落地 + pattern-audit 时间线 |
| 2026-06-15 | rev-3（已接受，PR #25）| 增 §2.4「执行内 ephemeral cookie 写回通道」+ 窄 API `ctx.setEphemeralCookie`——解 XJT body-token 缺口（证据 `adapters_tests/XJTU/dean/pac.txt`）。四重栅栏：仅 passthrough origin、不覆盖凭证、永不收割、执行即弃。§2.3 剥除规则不变（纵深防御）。触红线 #1/#6。契约改动见 §4（Gate B） |
| 2026-06-16 | rev-3a（editorial，B4 计划拍板）| §2.4 四重栅栏违例处置从「抛结构化权限错误」修正为「静默丢弃 + ctx.log("warn")、不抛错」——理由：不给 adapter 探测栅栏边界的异常信号（同 B1 纵深防御哲学）。语义不变（写入仍被拒绝、绝不被 honor），仅实现行为明确化 |
| 2026-07-04 | **rev-4（已复核并接受，#79 P0-3）** | **推翻 rev-2 决策点 8「body 不设独立上限」**：新增 §2.9——宿主 transport 层强制单响应 body 字节上限（`Content-Length` 预检 + 流式累计上限权威闸门，超限 `body_limit` + fail 不收割，占位 ~8 MiB 纳入 §2.8 校准）+ `Transport.fetch` 增 `AbortSignal`/cancel token、限额/fatal 时主动取消所有 in-flight 上游请求（认领 ADR-014 §4.7）；决策点 8/10 与 §4 同步。理由：宿主在字节进 QuickJS 前已整体读入宿主堆，QuickJS OOM 兜底护不住宿主 transport 阶段。**安全不变量不变**（不触注入/脱敏/白名单），仅加资源闸门 + 取消。 |
