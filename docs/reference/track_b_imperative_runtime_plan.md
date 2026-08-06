# Track B 实施草案 —— 命令式 requestGraph 运行时（受限 `ctx.fetch` + Broker）

> **状态**：**Broker 核心零件 B1–B6 已落地（2026-07-14）**（`server/src/runtime/broker/` + `client/lib/core/broker/` 双端 + golden/集成测试，CI 双跑）；本文落地 [ADR-009 §4](../adr/adr_009_fetch_credential.md) 的运行时清单与 [#3](https://github.com/NanCunChild/elecon/issues/3)，现留作**实现依据 / 历史**，剩余接线（限额执行、adapter 运行时桥接）随实现推进。
> **术语（ADR-022）**：旧称「fetch 模式」= 今 **imperative requestGraph**；旧称「parser 模式」= 今 **declarative requestGraph**。`ctx.fetch` 方法名不变。
> **🔒 承重路径**：触碰红线 #1（凭证）。按 AGENTS.md §1，**AI 不得独自闭环**——本草案由 AI 起草，
> 实现与测试须人工主导 + 安全检查清单 + ≥1 人工审。本文只是把决策展开成可审查的小 PR 切片，不替代审阅。
> **不含**：declarative requestGraph（ADR-005/008 已落地）、登录/认证流程（属 ADR-012 WebView 收割，见下 §0）。

---

## 0. 本轮实测输入（决定形态的事实依据）

两批本地逆向 spike（`adapters_tests/`，已脱敏、gitignore，不进发布流程）确立了两类截然不同的取数形态：

| | **XJT 教务（dean）** | **XIDIAN（ehall / card / yjspt …）** |
|---|---|---|
| 数据 | 公开通知，**无学生凭证** | 成绩 / 一卡通 / 课表，**学生凭证** |
| 认证 | 无；但有 **JS 反爬挑战**（多步握手） | **CAS/SSO**：AES 密码 + 滑块验证码 + 跨子域 ticket 链 |
| 凭证载体 | `client_id`（挑战响应 **body**，**无 Set-Cookie**） | `CASTGC` cookie（ids 下发）+ 各服务 session cookie |
| 等价物 | — | redirect URL 里的 `ticket` / `openid` / `jsessionid`（红线 #1） |
| 取数 | `ctx.fetch` 多步，全 passthrough | 登录后 POST `.do` → JSON |

**两条关键结论（影响 adapter 形态，见 §1）：**

1. **认证不进 adapter。** XIDIAN 登录涉及明文密码、滑块验证码图像匹配、跨子域 CAS 重定向链（每跳携带 ticket 等价物）。这既超出"薄归一化"，又会让 adapter 触碰红线 #1 的等价物。**登录归 ADR-012 的 WebView 会话收割**；imperative/declarative adapter 一律假设 **Broker 已注入会话凭证**，只管取数 + 解析。
2. **XJT 的 body-token 是 ADR-009 现有模型未覆盖的真实缺口。** `fetch.py:73-74` 实测：`client_id = data.get('client_id')` 后 `session.cookies.set(...)` **手动**注入——origin **不下发 Set-Cookie**。ADR-009 §2.4 的 per-execution jar 只捕获 Set-Cookie、§2.3 又剥除 adapter 自设 Cookie 头 → 此流程**当前跑不通**。需 ADR-009 修订（见 §5，🔒 人工 + ADR）。

---

## 1. adapter 形态裁定（落到运行时的影响）

- **认证边界**：adapter **永不登录**。Broker 注入的会话来源 = ADR-012 WebView 收割 + §4 收割桥接。Track B 只消费凭证库里已有的条目。
- **多数 XIDIAN 取数 = declarative requestGraph**：登录后就是「带 cookie POST `.do` → 解析 JSON」，请求可静态声明（manifest `requests[]`），核心代取 + 注入 + 脱敏，adapter 纯解析。**不需要 imperative**——优先走更安全的 declarative。
- **imperative 仅用于运行中途需要 adapter 计算的场景**：反爬挑战（解析内联 JS 算 answer、伪造指纹）、依赖前一步响应体动态拼下一请求。XJT dean 是当前唯一确认的 imperative-only 案例。
- **跨子域 allow**：CAS 链跨 `ids→ehall→yjspt→v8scan`。若某取数确需 `ctx.fetch` 跟随这类链，manifest `network.allow` 须把**每一跳子域**列入（ADR-009 §2.5「每跳须仍在 allow 内」），且中间 `Location`（含 ticket）由 Broker 跟随、永不回交 adapter。

---

## 2. 组件与 PR 切片（每片可独立审查）

两端**共享同一净化/注入/脱敏规格**，分别实现：

- 客户端：`adapter_runtime.dart`（Dart 核心，client-direct）
- 服务端：`server/src/runtime/sandbox.ts`（campus-relay；`public` 永不参与，红线 #2）

| PR | 内容 | 🔒 |
|---|---|---|
| B1 | Broker 核心：allow 匹配（uri-template）+ inject/passthrough 分流 + 凭证注入（ADR-013 `credentials` 块）| 🔒 |
| B2 | 出站请求头净化（剥 Cookie/Authorization/Proxy-Authorization；其余 allowlist）+ 响应头 allowlist 脱敏 | 🔒 |
| B3 | 重定向核心跟随：max 5 跳 + 每跳 allow 校验 + 中间 Location 不外泄 | 🔒 |
| B4 | per-execution cookie jar（两分区，见 §3）+ Set-Cookie 捕获 | 🔒 |
| B5 | 耐久 cookie 收割桥接 → ADR-012 库（判据 b，见 §4）| 🔒 |
| B6 | 异步 handler 运行时：job queue pump + await + 限额（§2.8 校准）| 🔒 |
| B7 | 录制/回放夹具机制 + 宿主侧单测 + imperative 双跑 | |
| B8 | pattern-based 后置审计（token-pattern 扫描，告警不阻断；随首个 imperative adapter 建初版清单）| |

> B1–B6 的 Dart 与 TS 两份实现必须对同一组**净化/脱敏 golden 向量**双跑，杜绝两端漂移。

---

## 3. per-execution cookie jar —— 两分区设计

jar **仅限单次执行**，不跨执行、不经 public、对 adapter 全程不可见。内部分两区，**严格隔离**：

1. **Broker 注入区（credential-backed，只读于 adapter）**
   - 来源：凭证库按 `credentials.<name>.scope` 命中注入。
   - adapter 不可写、不可读其值。
   - origin 在本次执行中 Set-Cookie 同名 cookie 时，**以 origin 最新值为准**（session 轮换），并作为收割权威（§4）。

2. **adapter-ephemeral 区（gap-fix，仅 passthrough origin）** —— *依赖 ADR-009 修订，§5*
   - 解 XJT body-token 缺口：adapter 拿到挑战响应体里的 `client_id`，需后续请求携带，但 origin 无 Set-Cookie。
   - **强约束（全部由 Broker 强制，缺一不可）**：
     - a. 仅可作用于**不被任何 `credentials.scope` 覆盖的 passthrough origin**——永不触碰凭证域；
     - b. **永不覆盖** Broker 注入区的同名 cookie；
     - c. 执行结束**即弃**，**永不进收割**（§4 收割只认 Broker 注入区 + origin Set-Cookie，不认 adapter-ephemeral）；
     - d. 经**专用窄 API** 写入（见 §5），不复用 `init.headers.Cookie`（§2.3 的 Cookie 剥除规则保持不变，纵深防御）。
   - **为何安全**：实测两类流程里，唯一需要它的是零凭证的 XJT；所有 credentialed 流程（XIDIAN）的会话都走 Set-Cookie/redirect（Broker 区），从不需要 adapter 自设。故该区被「passthrough-only + 不覆盖凭证 + 不收割 + 执行即弃」四重栅栏围死，不削弱任何 credentialed 路径。

---

## 4. 耐久 cookie 收割桥接（→ ADR-012）

执行结束时，核心从 jar **Broker 注入区 + origin Set-Cookie 状态**收割耐久 session 入 ADR-012 库：

- **判据 b**：只收割 manifest `credentials.<name>` 显式声明 ref 的 cookie（`type: cookie`）；其余按瞬态丢弃。
- **匹配**：RFC 6265 §5.1.3/5.1.4 方向（scope host domain-match cookie Domain；cookie Path 为 scope pathPrefix 前缀）。
- **adapter-ephemeral 区不参与收割**（§3 约束 c）。
- 收割是宿主侧安全代码，随 B5 人工审。

---

## 5. ADR-009 修订（🔒 已确认必需，阻塞 B4 第 2 分区 / XJT 端到端）

**问题**：XJT `client_id` 经 body 下发、无 Set-Cookie → 当前 ADR-009 跑不通。

**抓包已确认（2026-06-15，`adapters_tests/XJTU/dean/pac.txt`）**：全程**零 `Set-Cookie`**。挑战页 JS 自身
（`pac.txt:119`）`document.cookie = "client_id=" + data.client_id + "; path=/; max-age=86400; ..."`
——`client_id` 取自 `POST /dynamic_challenge` 的**响应 JSON body**，由浏览器端 JS 写 cookie，origin
**不下发 Set-Cookie**。故 per-execution jar（只抓 Set-Cookie）拿不到、§2.3 又剥 adapter 自设 Cookie 头。
**结论：方向 A 必需，非可选。**`max-age=86400` 看似耐久，但 XJT manifest 无 `credentials` 声明 →
判据 b 不收割 → 仍按瞬态执行后即弃，无需特判。

**方向 A（窄通道）**：ADR-009 §2.3/§2.4 增一条受控例外 + adapter-sdk 增窄 API：

```ts
// CtxImperative 增（仅 imperative requestGraph、仅 passthrough origin 生效）
setEphemeralCookie(name: string, value: string, opts: { domain: string; path?: string }): void;
```

- Broker 校验 `domain` 落在某 passthrough origin 内、且**不**落在任何 `credentials.scope` 内 → 否则抛结构化权限错误。
- 写入仅 §3 第 2 分区，执行结束即弃，永不收割、永不覆盖凭证。
- `init.headers.Cookie` 仍被无条件剥除（纵深防御不变）。
- **安全论证**：`client_id` 非学生凭证（是反爬 token）；adapter 经 §2.5 body 透传**本就看得到它**；
  允许其写回**同源 passthrough** cookie，不增任何超出 body 透传既有面的外泄面。

**落地动作**（🔒 人工主导）：
1. ADR-009 修订（AI 可起草，人工 review，循 ADR-009 自身先例）——§2.3/§2.4 增受控例外 + §2.1 数据流加第 2 分区。
2. `contract/adapter-sdk/types.d.ts` `CtxImperative` 增 `setEphemeralCookie`（契约改动，红线 #6，向后兼容：纯新增）。
3. B4 实现两分区 jar；school-xjt `index.js` 把当前「⚠️ 缺口」标注处替换为 `ctx.setEphemeralCookie(...)`。

---

## 6. 限额校准（ADR-009 §2.8，硬承诺）

§2.8 数值为临时占位。首个 imperative adapter（XJT dean）端到端跑通后，用真实多步握手实测校准并回填 ADR-009 §2.8 正式数值：单请求超时 ~10s / 累计 ~30s / 单次执行最大请求数 ~20（反爬多步可能吃预算，重点验证 20 是否够）。

---

## 7. 安全检查清单（随每个 🔒 PR 附，逐项自检）

- [x] 出站请求头：Cookie / Authorization / Proxy-Authorization 无条件剥除；其余 allowlist。
- [x] 凭证注入仅在 Broker、按 scope；adapter 入参/返回/日志均无凭证值。
- [x] 重定向中间 Location 不回交 adapter；每跳 allow 校验；max 5 跳。
- [x] 响应头 allowlist；Set-Cookie 不回交 adapter。
- [x] 出口 fail-closed：allow 外的 URL（含 body 外泄向量目标）一律拒绝。
- [x] passthrough origin 确不注入任何凭证。
- [x] adapter-ephemeral cookie：passthrough-only + 不覆盖凭证 + 不收割（若实现 §5）。
- [x] 收割只认判据 b 声明的 ref；未声明 cookie 绝不进库。
- [x] 响应 body / 请求 body 透传为**已接受风险**，确认仅官方签名 + code review 兜底。
- [ ] Dart / TS 两端对同一 golden 向量双跑一致。
