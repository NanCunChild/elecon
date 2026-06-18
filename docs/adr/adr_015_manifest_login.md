# ADR-015：manifest `login` 声明（WebView 登录配置契约扩展）

- **状态**：草案（Proposed）。本文改动 `contract/`（manifest schema），触碰红线 #6（契约即承重墙）且服务于红线 #1 的**凭证获取**路径（最高风险面）。按 [AGENTS.md](../../AGENTS.md) §1 + §10，**AI 不得独自闭环**：本草案由 AI 起草，**须经人工 + 安全检查清单审阅后才可接受并实现**。
- **日期**：2026-06-18
- **依赖**：[`adr_012_credential_store.md`](./adr_012_credential_store.md)（§2.2 核心托管 WebView 登录 + session 收割——本文为其声明面）、[`adr_001_contract.md`](./adr_001_contract.md)（manifest schema）、[`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md)（`credentials` 块；收割判据 b 依赖之）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（manifest 经官方签名，声明不可篡改）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（注入消费收割结果）
- **适用范围**：manifest 顶层 `login` 块的**数据形态 + 校验规则**——声明 WebView 登录的**起点 URL、导航域闭锁、成功检测**。**不含**：WebView UI / 平台集成 / cookie 提取实现（ADR-012 §2.2 落地）；凭证存储与注入（ADR-012 / ADR-009）。

---

## 1. 背景（Context）

ADR-012 §2.2 定下凭证获取主路径：**核心托管 WebView** 加载学校真实登录页 → 用户登录（验证码/2FA/SSO/JS 挑战由学校页自理）→ 核心从 WebView cookie jar **收割 session**（判据 b，复用 ADR-013 `credentials` 声明 + B5 `decideHarvest`）→ 存 ADR-012 凭证库。

但 manifest 当前**无处声明登录所需信息**：核心不知道①去哪个 URL 登录、②WebView 允许导航到哪些域（红线/§3.2 攻击面边界——必须闭锁，禁止导航出声明域）、③如何判定登录成功（触发收割）。这三项**校校异**（XIDIAN 走 CAS `ids.xidian.edu.cn/authserver/login` + 跨子域 ticket 链到 `ehall`；他校各异），天然属 manifest 声明（受 ADR-002 签名约束、不可被运行时篡改）。

**与 `credentials` 的分工**：`credentials`（ADR-013）声明「哪些 cookie 是凭证、注入到哪些 URL、收割哪些」；`login`（本文）声明「如何获取这些凭证（去哪登、导航边界、何时算成功）」。两者正交、配合：login 建立 session，credentials 判据 b 决定收割哪些。

---

## 2. 决策（Decision，草案）

> 以下为**待审议**取向，非既定事实。每条都需安全审阅确认。

### 2.1 顶层可选 `login` 块：登录起点 + 导航闭锁 + 成功检测

manifest 增一个**可选**顶层对象 `login`，与 `network` / `credentials` 平级。仅**带凭证的学校**声明它；公开数据（如 school-xjt 全 passthrough）不声明，缺省即无 WebView 登录。

```json
{
  "mode": "fetch",
  "network": { "allow": ["https://ehall.xidian.edu.cn/*"] },
  "login": {
    "url": "https://ids.xidian.edu.cn/authserver/login?service=https://ehall.xidian.edu.cn/new/index.html",
    "navigationAllow": [
      "https://ids.xidian.edu.cn/*",
      "https://ehall.xidian.edu.cn/*"
    ],
    "success": {
      "whenUrlMatches": ["https://ehall.xidian.edu.cn/new/index.html*"]
    }
  },
  "credentials": {
    "ehall-session": { "scope": ["https://ehall.xidian.edu.cn/*"], "type": "cookie" }
  }
}
```

字段定义：

- `login.url`：**string（https）**。核心托管 WebView 的**加载起点**——学校真实登录页。CAS 类可带 `?service=` 指定登录后跳转的服务（决定 ticket 链终点）。
- `login.navigationAllow`：**string[]（uri-template，≥1）**。WebView **导航域闭锁白名单**——WebView 只可导航到这些域，越界即拦截（ADR-012 §3.2：禁止导航出声明的登录域，闭锁新攻击面）。CAS 跨子域登录须把每一跳子域（`ids` → `ehall`）列入。**与 `network.allow` 正交**：login 域（auth/SSO）常不同于数据域；session cookie 在 login/nav 域下发，注入在数据域（network.allow）。
- `login.success.whenUrlMatches`：**string[]（uri-template，≥1）**。**成功检测**——WebView 导航**抵达**任一匹配 URL 即视为登录成功 → 触发收割（从 WebView cookie jar 收割判据 b 声明的 cookie）。须 ⊆ navigationAllow（否则 WebView 拦截该导航、永不判成功）。

**`login` 不含任何凭证值 / 口令**——只有 URL 与域模式。口令进的是学校页（非核心、非 adapter，ADR-012 §2.2）；核心只收割登录结果（session）。

### 2.2 校验规则（tools 校验器，随本 ADR 落地）

| # | 规则 | 级别 |
|---|---|---|
| L1 | `login.url` 须 https；`navigationAllow` 项非 https → 警告 | error / warn |
| L2 | `login.url` 须落在 `navigationAllow` 内（WebView 起始页须可导航） | error |
| L3 | `login.success.whenUrlMatches` 每条须 ⊆ `navigationAllow`（否则 WebView 拦截导航、永不判成功） | error |
| L4 | 声明了 `login` 但 `credentials` 为空 → 警告（登录建立的 session 无声明 ref，收割判据 b 将丢弃一切） | warn |

> **不强制** `credentials.scope` ⊆ `navigationAllow`：session cookie 的下发域（nav）与注入域（network.allow / scope）可不同（CASTGC 在 `ids` 下发、ehall session 在 `ehall`；注入在数据域）。收割由 B5 `decideHarvest` 按 RFC 6265 方向匹配 WebView cookies × credentials.scope 落实，跨域正确性靠实测夹具兜（落地阶段）。

---

## 3. 备选与取舍（Alternatives）

| 方案 | 取舍 | 裁定 |
|---|---|---|
| **A. 顶层 `login` 块（本文选）** | 与 `credentials`/`network` 平级、声明式、签名覆盖、校校异自然落 manifest；WebView 只读 manifest 配置、不内置任何校特例。 | **选用** |
| B. 登录配置硬编码进核心 / 单独配置文件 | 不动 manifest。**舍**：校异登录信息脱离签名 manifest → 不可信、不可热替换，违背「可热替换 + 签名覆盖」主线。 | 拒绝 |
| C. 让 adapter 提供登录流程（JS） | 最灵活。**舍**：adapter 触碰登录 = 触红线 #1/#5（ADR-012 §2.x 已否决）。 | 拒绝 |

---

## 4. 已知约束与风险（Consequences，草案）

1. **契约改动（红线 #6）。** manifest schema 增可选 `login` 块——**向后兼容**（纯新增、可选；既有 manifest 不受影响）。须与 ADR-001 §5 协调、随本 ADR 落地 schema + 校验器。
2. **`login` 是 WebView 攻击面的声明边界（ADR-012 §3.2）。** `navigationAllow` 即 WebView 导航闭锁白名单——**实现侧必须强制**（导航出界即拦截），声明侧由本文 + 校验器（L2/L3）保证自洽。声明面经官方签名（ADR-002），不可被运行时篡改。**残余风险**：登录页自身的 JS 在 WebView 内执行（学校页面，隔离于 adapter 运行时与他校凭证，ADR-012 §3.2）——这是 WebView 方案的既有已接受面，本文不扩大。
3. **成功检测是「导航抵达 URL」启发式。** `whenUrlMatches` 适配 CAS 这类「登录后跳转到服务页」的主流模式；少数学校若无稳定跳转 URL（如 SPA 内部状态变化），本启发式可能不灵——落地阶段按实测补充检测手段（如 cookie 出现）时再扩 schema（向后兼容新增）。本版只钉「导航抵达」。
4. **跨域收割正确性靠实测夹具。** credentials.scope 与 navigationAllow 域可不同（§2.2 注），静态校验不强制其关系；收割（B5）的跨域匹配正确性须由落地阶段的录制夹具回归（同 school-xjt 的 `smoke:xjt` 范式）。
5. **🔒 服务红线 #1 最高风险面 + 触契约。** schema + 校验器 + 后续 WebView 落地及其测试，按 AGENTS.md §1 不得 AI 独自闭环，须人工主导 + 安全清单 + ≥1 人工审。

---

## 5. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

- **本 PR（契约面）**：`contract/manifest.schema.json` 增可选 `login` 块（url / navigationAllow / success.whenUrlMatches）；`tools/` 校验器增 L1–L4；validator smoke 增 login 用例。**纯新增、向后兼容。**
- **后续（ADR-012 §2.2 落地）**：核心托管 WebView 登录屏（Flutter；导航域闭锁 = navigationAllow、上下文隔离、成功检测 = whenUrlMatches、收割后销毁）；WebView cookie jar → `decideHarvest`（B5 复用）→ CredentialStore 接线；WebView 包选型（待调研）；生命周期（过期/登出抹除）。
- **交叉引用**：ADR-012 §4 落地清单指向本 ADR（登录声明面）；ADR-001 §5 / ADR-000 §6 索引登记。

---

## 附录 A：修订记录

| 日期 | 版本 | 摘要 |
|---|---|---|
| 2026-06-18 | 草案 | 起草：manifest 顶层可选 `login` 块（url / navigationAllow / success.whenUrlMatches），落 ADR-012 §2.2 WebView 登录的声明面；校验器 L1–L4；与 `credentials` 正交（login 获取、credentials 注入/收割）。拒硬编码 / adapter 参与登录。🔒 待人工 + 安全清单复核后接受。 |
