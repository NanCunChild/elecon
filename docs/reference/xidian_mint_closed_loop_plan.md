# XIDIAN 全闭环 + SSO mint 签票 —— 设计与落地计划

- **状态**：**已批准 · 实施中**（2026-07-20）。默认降级阶梯 hidden WebView → headless → visible（§4.4，ADR-017 §2.7“少模拟优先”）；`forms` 可在签名 manifest 内收窄或调整两个静默级。触红线 #1 的路径须人工主导 + 安全清单，AI 不得独自闭环（AGENTS.md §1 + ADR-017 §4.9）。
- **依赖**：ADR-017（母凭证 + 静默签票）、ADR-016（WebView 登录）、ADR-009（Broker 注入）、ADR-012（凭证库）、Track B fetch 运行时（B4–B6）。
- **目标**：**一次可见登录**收割 `CASTGC`，之后按需静默换取 ehall / 一卡通 / 图书馆 session，再经 official fetch adapter 取数，UI 只看到能力结果（不见凭证）。

---

## 1. 现状盘点（已有 vs 缺口）

| 层 | 已有 | 缺口 |
|---|---|---|
| 契约 | `credentials.role: sso-master`、`login.ssoMint.forms` schema；校验器 M1–M7 | 声明式过期判据（rev-2 §2.9）未进 schema；body/header 凭证扩展见 Proposed ADR-029 |
| 内置目录 | 认证事实已迁到验签 manifest；外部 XIDIAN manifest 已声明 **ehall + card** mint | **library 未进 mint 白名单**；energy/xxcapp 仍受 ADR-029 阻塞；card 待真机字段校准与签名发布 |
| 登录 | 可见 WebView 收割（判据 b）→ `CredentialStore` | 登录后无「服务就绪」编排；无 mint 触发点 |
| mint 纯逻辑 | `buildMintPlan` / `classifyMintResult` / `SsoMinter` 接口 | — |
| mint 执行 | `HeadlessSsoMinter`、隐藏 WebView minter + fake Transport 测试；Session debug 已装配 | `via` adapter mint 未做；红线 #1 真机签收仍待人工执行 |
| 降级阶梯 | ADR-017 §2.7 已定「少模拟优先」 | PR-5 编排器未实现 |
| adapter | 外部 `school-xidian` 已含 E-Hall、空教室和 card imperative 能力 | card 真机字段校准；library/energy 未接；无最新版 catalog 签名包发布闭环 |
| 逆向夹具 | `adapters_tests/XIDIAN/*`（ids/ehall/card/energy/aircon/…） | card 脱敏原响应、energy 校园网句柄链和 aircon token 获取方式待补 |

**结论**：签票**内核草案在**，全闭环缺三块——**(A) 精确声明校准 (B) 会话侧 ensure+mint 编排 (C) XIDIAN fetch adapter + 取数 UI 路径**。

---

## 2. 目标数据流（闭环）

```
┌─────────────┐  可见 WebView   ┌──────────────┐
│ 用户选校登录 │ ─────────────► │ CredentialStore│
└─────────────┘  收割 ids-cas   │  ids-cas      │
                 (+ 可选 ehall) │  ehall-session│
                                │  card-session │ …
                                └───────┬───────┘
                                        │
         runCapability("grades.list")   │
                    │                   │
                    ▼                   │
         ┌──────────────────┐           │
         │ ensureCredential │◄──────────┘
         │  map cap → refs  │
         └────────┬─────────┘
                  │ 缺 ref？
         ┌────────┴────────┐
         │ buildMintPlan?  │  有 ids-cas + ssoMint 声明
         │ HeadlessSsoMinter│  注入母票 @ CAS only
         │  → 收割目标 ref │
         └────────┬────────┘
                  │ tgcExpired / 无计划
                  ▼
         可见 WebView 重登（安全底）
                  │
                  ▼
         Broker 注入目标 session → adapter fetch → schema 校验 → UI
```

**不变量（全程）**

1. 母凭证 / ST / Set-Cookie / 带票 URL **只在核心**（红线 #1）。
2. 母凭证 scope **仅** `ids.xidian.edu.cn`，与下游域不重叠（M4）。
3. mint 目标 ∈ `ssoMint.services` 白名单 fail-closed。
4. adapter **不见**凭证值；DEPLOY 无论 catalog / 本地导入都只运行 official，DEV-Sideload 可全能力调试但凭证值仍留核心、产物不可分发（红线 #4/#5，ADR-024/033）。
5. 无 `sso-master` / 无 `ssoMint` → 行为与旧版逐服务可见登录一致（§2.6）。

---

## 3. XIDIAN 服务白名单与 mint 校准

来自 `adapters_tests/XIDIAN`（须在真机/本地脚本再验一次后回填，**禁止臆造**）：

| credential ref | CAS `service`（校准源） | 成功 URL 模式 | 备注 |
|---|---|---|---|
| `ehall-session` | `https://ehall.xidian.edu.cn/login?service=https://ehall.xidian.edu.cn/new/index.html`（见 `ehall/session.py`） | `https://ehall.xidian.edu.cn/new/index.html*` | 课表/成绩/考试/空教室均走 ehall + `useApp` |
| `card-session` | `https://v8scan.xidian.edu.cn/home/openXDOAuth2Page`（见 `card/balance.py`） | `https://v8scan.xidian.edu.cn/myaccount/*` 或含 openid 落地页 | 下游还可能需 openid 解析——**openid 不得当凭证外泄**；若落 URL 参数，收割策略需专项（见 §6） |
| `library-session` | 待 `library/borrow.py` / 逆向补全 | `https://hyytsgxzs.xidian.edu.cn/*` | 现占位根路径 |
| `ids-cas` | n/a（母票） | n/a | 仅注入 CAS 端点 |

**首登 `login.url`**：保持 ehall 目标（现有），一次可见登录同时收割 `ids-cas` + `ehall-session`。

**不进 mint 的服务**

- **energy（水电）**：每请求 body 签名（ADR-017 §2.8 盲区）→ **默认不静默 mint**，可见 WebView 或后续 PR-6 签名钩子；本闭环 v1 不接。
- **xxcapp**：未逆向清楚前不进白名单。

建议更新 `schools.dart` 的 `ssoMint.services`（声明改动，非执行体）：

```dart
services: {
  'ehall-session': SsoMintServiceDecl(
    service: 'https://ehall.xidian.edu.cn/login?service=https://ehall.xidian.edu.cn/new/index.html',
    success: ['https://ehall.xidian.edu.cn/new/index.html*'],
  ),
  'card-session': SsoMintServiceDecl(
    service: 'https://v8scan.xidian.edu.cn/home/openXDOAuth2Page',
    success: ['https://v8scan.xidian.edu.cn/myaccount/*'],
  ),
  // library：逆向校准后再写死 service=
}
```

`navigationAllow` / broker `allow` 须覆盖整条回跳链（已含 ids/ehall/v8scan/hyytsgxzs）。

---

## 4. 核心编排（会话侧，设计）

### 4.1 能力 → 凭证映射（核心声明，非 adapter）

| capability（目标） | 所需 ref |
|---|---|
| `grades.list` / `schedule.week` / `exam.list` / `classroom.available` | `ehall-session` |
| `card.balance` / `card.transactions` | `card-session` |
| `library.loans` | `library-session` |
| `notice.list`（jwc 公开） | 无 |

映射放在 **核心**（`SchoolDescriptor` 或未来签名 manifest 的 `capabilities[].requiresCredentials`），adapter 不得自报「我要母票」。

### 4.2 `ensureCredential(ref)` 伪码

```
ensureCredential(ref):
  if store.has(schoolId, ref): return ok
  plan = buildMintPlan(login, ref)
  master = store.find sso-master for school
  if plan != null && master != null:
    outcome = minter.mint(ref)   // HeadlessSsoMinter v1
    if outcome == success: return ok
    if outcome == tgcExpired: → visibleLogin(reason: tgc)
    if outcome == blockedOutsideNav: → fail / 可见兜底
  else:
    visibleLogin(serviceUrl for ref)  // 逐服务可见
  // 可见登录成功后再 has(ref) 校验
```

### 4.3 `runCapability` 接线

在现有 `SessionController.runCapability` **之前**：

1. 解析 `requiredRefs(capability)`；
2. 对每个 ref `await ensureCredential`（串行；失败短路）；
3. 再 `service.run(...)`（现有 Broker 按 scope 注入子 session）。

🔒 `HeadlessSsoMinter` 的 `resolver` / `putCredential` / `transport` 均闭包在核心，UI 零凭证。

### 4.4 降级阶梯（本闭环目标 = 三级）

| 级 | 策略 | 说明 |
|---|---|---|
| **L1 hidden WebView** | 隐藏/离屏 WebView 驱动同一 `MintPlan` | 默认主路径；平台能力门禁（Android/iOS 先；OHOS 另开） |
| **L2 headless** | `HeadlessSsoMinter` + Broker 注入母票 | 已验证站点的协议模拟优化；须合规清单（ADR-017 §4.2） |
| **L3 visible WebView** | 用户可见登录（安全底） | 无 master / 无 ssoMint / 两个静默级皆失败 |

**执行顺序**：`ensureCredential` 对可 mint 的 ref：`has?` → `(平台能力 ∩ manifest forms)` 中的静默级 → **L3**。缺省顺序为 **L1 → L2 → L3**；任一静默级非成功均继续下一静默级，不在低级猜测失败原因。无 `sso-master` 则直接 L3。

| 切片 | 范围 |
|---|---|
| **M1–M2** | HTTP headless + visible 基础闭环 |
| **M6 / PR-5（代码已起草）** | hidden WebView + `forms` + 平台能力交集；Android/iOS profile/cookie 隔离仍须真机与人工安全复核 |

headless 属协议模拟合规灰度；**不得默认进发版**直至合规评估通过（ADR-017 §4.9）。

---

## 5. school-xidian adapter 演进

### 5.1 分阶段能力

| 阶段 | mode | capabilities | 凭证 |
|---|---|---|---|
| 现网 | parser | `notice.list`（jwc） | 无 |
| **闭环 v1** | **fetch**（official） | `grades.list`、`schedule.week`（ehall） | `ehall-session` |
| 闭环 v1.1 | fetch | `card.balance` | `card-session` |
| 后续 | fetch | exam / classroom / library | 对应 ref |

### 5.2 adapter 边界（红线 #5）

- 只声明 `requests` + 解析归一化；**不**登录、**不** mint、**不**读 cookie 值。
- ehall 业务：`useApp(appId)` + 业务 POST/GET（逻辑来自 `adapters_tests/XIDIAN/ehall/*`，脱敏夹具驱动测试）。
- 网络 `allow` 仅业务域；**不含** `ids.xidian.edu.cn`（母票域只给登录/mint 核心路径）。

### 5.3 发布

签名 bundle + catalog 条目 + 端点 D；`SchoolDescriptor.adapterId: school-xidian` 已占位。发布前门禁见现有 loader 文档。

---

## 6. 风险与开放点

| # | 风险 | 对策 |
|---|---|---|
| R1 | 母凭证泄露面 | 注入仅 CAS；日志打码；安全清单 + 人工审 |
| R2 | card openid 落 URL | **ADR-020 已接受**（[`adr_020_url_query_credential.md`](../adr/adr_020_url_query_credential.md)：`type: query` + 核心收割/注入）。**实现落地前** card mint 不得声称闭环；v1 可先只做 ehall |
| R3 | headless 合规 | v1 限 debug/灰度；发版前合规评估；v2 隐藏 WebView 优先 |
| R4 | TGC 静默失效 | `classifyMintResult` → tgcExpired → 可见重登；不猜原因 |
| R5 | service URL 漂移 | 声明面可热更新（签名 manifest）；逆向夹具回归 |
| R6 | energy 签名 | 不进 v1；§2.8 默认可见 / PR-6 需求触发 |
| R7 | AI 越权实现 | mint 接线、Broker 注入、store 写路径 = 人工主导 PR |

---

## 7. 落地 PR 切分（小步、可审）

| PR | 内容 | 主导 | 红线 |
|---|---|---|---|
| **M0** | 校准 `schools.dart`：`ehall-session` mint 条目 + card service URL；注释去掉「域根占位」 | AI 可起草，人审 URL | 声明面 |
| **M1** | `ensureCredential` + 能力→ref 映射 + `runCapability` 前挂钩；失败降级可见登录 | ✅ 已合 | #1 |
| **M2** | 装配 `HeadlessSsoMinter`（真实 Transport + store resolver）；集成测（fake 链 + 可选 debug 真机） | ✅ debug 会话装配已合；真机冒烟 **runbook 已备待人工执行**（[`xidian_smoke_runbook.md`](./xidian_smoke_runbook.md)，红线 #1 人工主导） | #1 |
| **M3** | `school-xidian` fetch：`grades.list`（夹具驱动）；manifest network/credentials | AI 解析 + 人审 fetch 边界 | #1 #5 |
| **M4** | UI：设置页「凭证 ref 列表 / 重新登录」✅ + 首页**按需取数区**（成绩/课表/空教室，点击触发 `runCapability`→静默 mint/可见登录）✅（`capability_sections.dart` + 解码器/单测） | AI 可做 UI | UI 不见值 |
| **M5** | card mint + `card.balance`（依赖 R2 裁定） | 人工 | #1 |
| **M6** | PR-5 三级阶梯 + `forms` schema（可另开） | 人工 | #1 #6 |

**明确不做（本闭环）**：PR-6 body 签名钩子；OHOS 离屏 WebView；侧载 mint；adapter 持 CASTGC。

---

## 8. 验收标准（XIDIAN 闭环 Definition of Done）

1. 用户在可见 WebView **只登一次** IDS → store 含 `ids-cas`（及通常 `ehall-session`）。
2. 无 ehall session 时点「成绩」→ **静默** headless mint → 有 `ehall-session` → `grades.list` 返回合法 schema（夹具或 debug 真机）。
3. 人为删掉 `ehall-session`、保留 `ids-cas` → 再次取数自动 mint，**不**弹登录页。
4. 删掉 `ids-cas` 或 mint 判 tgcExpired → **唯一**路径是可见 WebView。
5. 全程日志/诊断 **无** cookie 明文；adapter isolate 堆栈无凭证值。
6. 无 `ssoMint` 的假学校回归：行为与旧版一致。
7. 安全清单勾选 + ≥1 人工审（红线 #1 路径）。

---

## 9. 与 ADR-017 落地清单对照

| ADR-017 §5 | 本计划 |
|---|---|
| PR-1 契约 | ✅ 已合 |
| PR-2 收割母票 | ✅ 声明 + 收割路径已有 |
| PR-3 静默换票 | 执行体 + Session debug 接线 ✅（M1–M2）；release 仍 fail-closed |
| PR-4 UI | **M4** |
| PR-5 阶梯 | **M6**（v2） |
| PR-6 签名钩子 | 不做（需求触发） |

---

## 10. 建议执行顺序（本周可开）

1. **M0** 声明校准（低风险、可立刻合）。
2. 并行：M3 夹具 + ehall 解析草案（无凭证路径可 AI 推进）；M1/M2 设计评审 + 人工开工。
3. M4 最小取数 UI。
4. 真机冒烟 → 安全清单 → 再谈 M5 card。
