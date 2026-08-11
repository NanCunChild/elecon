# ADR-020：URL query 凭证（openid 等）收割与注入

- **状态**：**已接受（Accepted）** · **2026-07-22 经人工评审批准**（§5 开放问题 O1–O5 全部勾决，见该节）。触碰红线 #1（凭证）与 #6（契约）。按 [AGENTS.md](../../AGENTS.md) §1：**实现与测试仍须人工主导 + 安全清单 + ≥1 人工审**，AI 不得独自闭环 harvest/inject/契约落地。
- **日期**：2026-07-22
- **依赖**：
  - [`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（Broker 注入 / 脱敏 / 重定向跟随）
  - [`adr_012_credential_store.md`](./adr_012_credential_store.md)（`CredentialEntry` 存储）
  - [`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md)（`credentials` 声明）
  - [`adr_017_sso_master_credential.md`](./adr_017_sso_master_credential.md)（静默 mint 后收割下游）
- **被依赖**：XIDIAN `card-session` mint 闭环（R2）、后续同类「会话落在 URL 参数」校；**不**自动解锁 form-body token（见 §2.8）
- **相关**：[`docs/reference/xidian_mint_closed_loop_plan.md`](../reference/xidian_mint_closed_loop_plan.md) §6 **R2**；`adapters_tests/XIDIAN/card/balance.py`
- **适用范围**：凭证**值**出现在 URL **query**（偶见 fragment）时，如何**收割进核心 store**、如何在出站请求**由核心注入**、manifest 如何声明。**不含**：响应 body 内 token 的通用收割（既有 body 透传残余风险）；form-body / 签名请求注入（ADR-017 §2.8 / PR-6）。

---

## 1. 背景（Context）

### 1.1 现状能力

| 面 | 现状 |
|---|---|
| `credentials.<ref>.type` | 仅 `cookie` \| `header`（manifest + Broker `InjectDecision.via`） |
| 收割 | 主要来自 `Set-Cookie` → jar → 按 scope 归 ref（ADR-009 / ADR-012） |
| 注入 | `cookie` → `Cookie` 头；`header` → `Authorization` 头（`assemble.dart`） |
| mint 成功 | 认 success-URL；子 session 仍靠 cookie 收割路径 |

### 1.2 探针证据（R2）

XIDIAN 一卡通（`adapters_tests/XIDIAN/card/balance.py`）：

1. CAS `service` = `https://v8scan.xidian.edu.cn/home/openXDOAuth2Page`
2. 登录后跟随重定向，从**最终/中间 URL** 解析 `openid=...`
3. 业务请求把 openid 放在 **query**：  
   `.../openMyAccount?openid=...`、`.../queryCardSelfTradeList?openid=...`
4. **不一定**有可复用的业务域 `Set-Cookie` 作为唯一会话材料；**openid 即凭证等价物**（红线 #1）

同类形态在国内高校并不少见（OAuth callback、微信 openid、ticket 落 query）。

### 1.3 问题陈述

1. **收割缺口**：现有收割不认 URL query → mint/登录后 store 无 `card-session` 可用值。
2. **注入缺口**：即便手写把 openid 塞进 store，`type: header|cookie` 无法正确构造业务 URL。
3. **等价物面**：openid 出现在 URL 时，重定向 `Location`、日志、adapter 可见响应均可能外泄——须与 cookie 同级脱敏纪律。
4. **声明面缺口**：manifest 无法表达「此 ref 是 query 参数、参数名是 `openid`」。

> **R2 原话**（闭环计划）：card openid 落 URL——收割是否进 store、是否当 cookie 等价物——**专项裁定**后再接 card mint。本 ADR 即该专项。

---

## 2. 决策（Decision）

### 2.1 定性：query 凭证 = 一等 `CredentialEntry`

**openid / ticket 等出现在 URL query 的可重放材料，与 cookie/header token 同级**：

- 只进可信核心 store（红线 #1）
- 日志 / 诊断 / dev 环缓冲默认打码（与 cookie 同规则；query 含凭证参数时整段 query 脱敏或按名剥除）
- **永不**以明文出现在 adapter 入参、回交 adapter 的 URL、未脱敏日志

**拒绝**：adapter 自己从 body/URL 解析 openid 后经 `ctx.fetch` 拼进下一请求（等于 adapter 持凭证）。

### 2.2 扩展 `credentials.<ref>.type`：新增 `query`

```json
"card-session": {
  "scope": ["https://v8scan.xidian.edu.cn/*"],
  "type": "query",
  "queryParam": "openid"
}
```

| 字段 | 约束 |
|---|---|
| `type` | 枚举扩展：`cookie` \| `header` \| **`query`**（MINOR，向后兼容） |
| `queryParam` | **`type === "query"` 时 required**；参数名（如 `openid`）；仅 `[A-Za-z0-9_.-]+` |
| `scope` | 与现网一致：注入/收割匹配的 URL 前缀；须 ⊆ `network.allow`（C 系校验） |

**校验器（建议编号）**：

- **Q1**：`type: query` ⇒ 必须有非空 `queryParam` 且匹配名字模式
- **Q2**：`type ≠ query` ⇒ 禁止出现 `queryParam`
- **Q3**：同一 adapter 内 `(scope 主机, queryParam)` 不得冲突歧义（两 ref 同参同域 → 拒）

`CredentialEntry.type` 防御性副本同步为 `query`；注入权威仍在**已验签 manifest**（ADR-012 §2.4）。

### 2.3 收割（Harvest）

在**核心**侧，于以下时机扫描 URL 的 query（及可选 fragment，见开放问题 O1）：

| 时机 | 说明 |
|---|---|
| WebView 登录导航 | 到达 `login.success` 或等价成功态时，对**当前 URL** 做 query 收割 |
| SSO mint 完成 | `classifyMintResult` 成功且得到最终 URL 时 |
| 重定向链 | Broker **自行跟随**的跳转中，对**每一跳** `Location` 解析 query（值只进核心，**Location 仍不回交 adapter**，ADR-009 §2.5） |

**匹配规则（判据 q）**：

1. 取 manifest 中所有 `type: "query"` 的 ref
2. 若 URL 命中该 ref 的 `scope`（与 cookie 相同的前缀语义），且 query 含 `queryParam` 键且值非空 → 将该值写入 `CredentialEntry.value`（覆盖同 ref 旧值）
3. **不**把 query 凭证写入 ephemeral cookie jar；**不**经 `Set-Cookie` 路径混收
4. 未声明的 query 键：**不收割**（减小误收 CSRF/追踪参数）

**与 cookie 收割共存**：同一登录流可同时收 `ids-cas`（cookie）与 `card-session`（query）。

### 2.4 注入（Inject）

扩展 `InjectDecision.via`：`cookie` \| `header` \| **`query`**。

当 `via === "query"` 且已 resolve 凭证：

1. 解析出站 URL
2. 设置/覆盖 query 参数 `queryParam = value`（**覆盖** adapter 或旧 URL 同名参数，防止 adapter 塞伪值）
3. 禁止把 value 写入 `Cookie` / `Authorization`
4. 出站前：`sanitizeRequestHeaders` 规则不变；**额外**对将写入诊断的 URL 做 query 脱敏

**fail-closed**：`type: query` 但 store 无值 → 与缺 cookie 相同，走 ensure/mint/可见登录，不发裸请求装成功。

### 2.5 脱敏与日志（红线 #1 等价物）

| 通道 | 规则 |
|---|---|
| 回交 adapter 的最终 URL | 若曾注入 query 凭证，回显 URL **必须剥除**对应 `queryParam`（或整段 query 打码）——实现可选，**默认剥除已声明 query 凭证键** |
| 响应头 `Location` | 已丢弃；不变 |
| DevLog / 崩溃报告 | 默认 redact query；与 cookie 一致 |
| 夹具 / git | 已有 token-pattern；增 `openid=` 等高危键（Track B 扫描对齐） |

### 2.6 与 mint / card 闭环的衔接

接受本 ADR 并落地后，XIDIAN 可：

1. 保留 `card-session` 的 `ssoMint.services` 条目（service URL 已与探针一致）
2. 将 `card-session` 声明为 `type: "query", queryParam: "openid"`
3. mint 成功 URL 落在 `myaccount/*` 或带 `openid=` 的页 → 判据 q 收割
4. `card.balance` / `card.transactions` adapter 只请求**无 openid** 的 path，由 Broker 注入

**在本 ADR 实现落地前**：`card-session` mint **不得**声称闭环完成；store 无合法 query 凭证则取数必须降级可见登录或失败（fail-closed）。

### 2.7 版本与契约改动清单（接受后实现 PR）

| 项 | 改动 |
|---|---|
| `contract/manifest.schema.json` | `credentials.*.type` 枚举 + `queryParam` |
| 校验器 | Q1–Q3 + smoke |
| Dart/TS Broker | harvest query；`assemble` 注入 query；golden 向量 |
| `CredentialEntry` / store | `type` 字面量扩展（无新加密语义） |
| ADR-001 / ADR-013 交叉引用 | 补记枚举扩展 |
| 文档 | 闭环计划 R2 → 已裁定；COVERAGE 一卡通行更新 |

**兼容**：纯新增枚举成员 + 可选字段 → **MINOR** 契约演进；旧 adapter 无 `query` 行为不变。

### 2.8 明确不在本 ADR（边界）

| 形态 | 处理 |
|---|---|
| **Library token / userId 在 HTML/JS body**（`postMessage` JSON，见 `library/borrow.py`） | **不**用本 ADR 的 query 类型覆盖。属 body 解析收割 + **form body 字段注入**，与 ADR-017 body-签名盲区同族；另开 ADR 或扩「form-field」类型时再做。**library mint 在 query ADR 接受后仍可能不够** |
| 固定写死在 CAS `service` URL 里的应用级 `openId`（若证实非用户凭证） | 可作为 mint `service` 字符串的**非密**常量进官方 manifest；须人工确认「非用户密钥」后才能进 git；**禁止**把用户 openid 写进仓库 |
| body 内嵌且参与签名的凭证 | ADR-017 §2.8 / PR-6，默认可见登录 |

---

## 3. 备选与否决

| 方案 | 结论 |
|---|---|
| A. **本 ADR：`type: query` + 核心收割/注入** | **采用** |
| B. 继续 `type: header`，把 `openid=xxx` 整串当 header | 否：业务要的是 query，硬套 header 会错协议 |
| C. adapter 解析 URL/body 后自行拼 openid | **否决**（红线 #1/#5） |
| D. 仅 cookie 模拟（让站点 Set-Cookie） | 否：源站不提供则无效 |
| E. 把 openid 当 ephemeral 非凭证 | **否决**：可重放身份材料，必须进 store 保密 |

---

## 4. 后果与风险（Consequences）

1. **URL 是高泄露面**：代理日志、崩溃、截图、分享链接。缓解：注入后回显剥离、日志 redact、夹具扫描。
2. **参数名校异**：靠 `queryParam` 声明，不硬编码 `openid`。
3. **与最长前缀注入**：query ref 与 cookie ref 同域时，仍按 scope 最长前缀选 ref；**禁止**同一请求注入两个不同 query ref 到同一 param（Q3 + 运行时 fail-closed）。
4. **mint 成功页可能无 openid、只在中间跳转出现**：故 §2.3 要求重定向链每跳扫描（仅核心可见）。
5. **🔒 红线 #1**：实现 PR 须安全清单 + 人工审；AI 不得独自合并 harvest/inject 路径。

---

## 5. 开放问题（已勾决 · 2026-07-22）

| # | 问题 | 裁定 |
|---|---|---|
| O1 | fragment（`#openid=`）是否收割？ | **v1 不收**；有证据再 MINOR 扩 |
| O2 | 注入时是否删除 adapter 提供的同名 query？ | **是**（覆盖），防伪值 |
| O3 | 回交 adapter 的 Request URL 是否永远无凭证 query？ | **是**（剥除已声明 query 凭证键） |
| O4 | query 存裸值还是带前缀？ | **只存裸值**；注入层只做 `param=value` 编码 |
| O5 | library form-body token 是否紧随本 ADR 做 020-bis？ | **否**；本 ADR 落地 card 后再开 |

---

## 6. 落地清单（Accepted 后）

- [x] 本 ADR 状态 → Accepted（2026-07-22 人工评审 + §5 O1–O5 勾决）
- [x] ADR-000 索引 + 闭环计划 R2 引用
- [x] 契约：manifest schema + 校验器 Q1–Q3 + smoke（PR #100/#103 已合入）
- [x] 日志 / 扫描：openid 等 pattern（scanner 已含）
- [~] Broker：query harvest + assemble 注入 + golden（Dart/TS 双跑）
      —— assemble/inject query 已由 golden（`inject-policy.json` 3 例）+ Dart `fetch_proxy` 集成测试覆盖；
      **query harvest 的 golden 双跑（`harvest.json` `queryCases` 7 例，两端替换原手写断言）为 2026-07-27 新增草案，待人工 + 安全清单复核**（红线 #1，不得 AI 独自闭环）。
- [ ] XIDIAN：`card-session` 改 `type: query` + `queryParam: openid`；M5 card 闭环（adapter 在 elecon-adapters 仓；真机验收未做）
- [~] 回归：无 query 声明的学校行为逐字节不变（cookie golden 11 例不变即证；真机全量回归待一卡通验收时做）

---

## 附录 A：修订记录

| 日期 | 版本 | 摘要 |
|---|---|---|
| 2026-07-22 | 草案 | 起草：为 R2（card openid 落 URL）新增 `credentials.type: query` + `queryParam`；核心在登录/mint/重定向链收割 query；出站由 Broker 注入 query；adapter 永不持 openid。明确 **不**覆盖 library body token。 |
| 2026-07-22 | 已接受 | 经人工评审批准；§5 O1–O5 按建议默认勾决。实现（schema/校验器/harvest/inject/XIDIAN card）仍按红线 #1/#6 须人工主导 + 安全清单，不得 AI 独自闭环。 |
| 2026-07-27 | 实现（待复核） | query harvest 由两端手写断言收敛为共享 golden 双跑：`harvest.json` 增 `queryCases`（7 例，新增空值 / 缺参 / 与追踪参数共存边界），`harvest.smoke.ts` 与 `broker_harvest_test.dart` 改 golden 驱动，两端各 golden 18 + 集成全绿。**属红线 #1 凭证路径，AI 起草，待人工 + 安全清单 + ≥1 人工审，未闭环。** |
