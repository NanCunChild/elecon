# Probe-001 · OHOS（鸿蒙）WebView 登录收割可行性探针

> **类型**：go/no-go 探针规格（gate）。延续 V1 ADR-000 §5.2 / ADR-003「VPN 三件套探针」范式：**未过探针不进实现，结果回写 [V1 ADR-016](../adr/archived/v1/adr_016_complex_login.md) §2.4 再定 WebView 选型。**
> **状态**：📋 待执行（spec 起草完成；执行须真机 / OHOS 模拟器 + 人工主导）。
> **关联**：issue #65 · ADR-016 §2.4（WebView 主路线）· ADR-015（`navigationAllow` / `success.whenUrlMatches`）· ADR-012 §2.2（凭证边界）· #17。
> **🔒 合规**：本探针走红线 #1（凭证收割路径）。代码与结论按 [AGENTS.md](../../AGENTS.md) §1 须人工主导 + 安全检查清单 + ≥1 人工审，**AI 不得独自闭环**；不提交真实凭证 / cookie（红线 #8）。
> **上真机前先桌面调研**：本规格定义的是真机 gate；上真机前先按 [`probe_001_research_outline.md`](probe_001_research_outline.md)（OHOS WebView API 桌面调研大纲）摸清各项 API 现状，只把「文档模糊 / 无文档」项带上真机，省真机成本。

---

## 1. 为什么先探针

ADR-016 把 WebView 定为复杂登录（CAS + 验证码类）的**主路线**：覆盖广、合规稳（验证码用户手解）、声明面已由 ADR-012/015 定。但其成立的前提是**宿主能在 WebView 内完成核心托管登录收割**——而 **OHOS（鸿蒙）上 WebView 的收割能力是当前最大未知**：

- OHOS 不是标准 Android，Flutter-OHOS 生态的 WebView 插件成熟度未知；
- 若 OHOS 上 WebView **读不到 cookie jar** 或 **拦不住导航**，则 WebView 主路线在鸿蒙上**不成立** → 须 headless 兜底或另寻方案。

因此选型前先 gate：探针验证三项核心能力，产出 go/no-go，回写 ADR-016 §2.4。

---

## 2. 探针目标（三项能力 = 验收标准）

收割链路所需的最小能力集，逐项 pass/fail。**任一 fail 即该候选包在 OHOS 上不可用于 WebView 收割主路线。**

| # | 能力 | 验收判据 | 对应核心调用 |
|---|---|---|---|
| **①** | **cookie jar 可读** | 登录成功后，宿主能从 WebView cookie jar 读出目标域 session cookie，**含 `HttpOnly`** 项；能按域/路径过滤。 | 交核心 `decideHarvest`（B5）；凭证只入可信核心（红线 #1） |
| **②** | **导航闭锁可拦** | 能在导航**发生前**拦截/否决（非事后回调），实现 ADR-015 `navigationAllow` 白名单闭锁（越界即拦）；能检测 `success.whenUrlMatches` 命中以触发收割。 | B3 重定向策略 / ADR-015 登录声明 |
| **③** | **隔离 + 销毁** | 可用隔离 profile（不污染主浏览态、不与其它会话串 cookie）；会话用后可销毁（清 cookie + 存储）。 | ADR-012 凭证边界 / 多账号隔离 |

> 附加观测项（不作 gate，但必须记录）：JS 注入可控性（注入时机/世界隔离）、`HttpOnly` cookie 是否需特殊 API、跨子域 cookie 在 CAS ticket 链中的可见性。

---

## 3. 候选包矩阵

逐候选跑 §2 三项，填下表（探针执行时填）：

| 候选 | ① cookie jar | ② 导航闭锁 | ③ 隔离/销毁 | OHOS 可用性 | 备注 |
|---|---|---|---|---|---|
| `flutter_inappwebview`（`CookieManager` + `shouldOverrideUrlLoading`） | ☐ | ☐ | ☐ | ☐ | ADR-016 倾向项；重；OHOS 支持待核 |
| `webview_flutter`（官方、轻） | ☐ | ☐ | ☐ | ☐ | cookie 提取 / 导航控制能力弱，预期 ① 偏弱 |
| OHOS 原生 Web 组件 + platform channel | ☐ | ☐ | ☐ | ☐ | 兜底：插件均不成立时，自写桥接 |

判据：`✅ pass` / `⚠️ 受限（注明条件）` / `❌ fail`。

---

## 4. 测试标的

**XIDIAN IDS CAS**（真实复杂登录，覆盖跨子域 ticket 链 + 滑块验证码）：

- 入口：`https://ids.xidian.edu.cn/authserver/login?service=https://ehall.xidian.edu.cn/new/index.html`
- 流程：`ids` 登录（密码 AES + 滑块验证码**用户手解**，探针不自动化验证码）→ CAS 颁 ticket → 重定向 `ehall` → 收割 `ehall` session cookie。
- 闭锁白名单（②）：仅放行 `ids.xidian.edu.cn` / `ehall.xidian.edu.cn`，越界即拦；`success.whenUrlMatches` ≈ `ehall.xidian.edu.cn/new/index.html`。

> 标的仅用于验证能力，**不收集、不提交任何真实凭证 / cookie 值**；记录中所有敏感值脱敏为占位符。

---

## 5. 证据格式（回写用）

每个候选 × 每项能力，记录：

1. **结论**：pass / 受限 / fail（受限须写触发条件）。
2. **证据**：API 调用片段 + 脱敏后的观测（如「`CookieManager.getCookies(url)` 返回含 `HttpOnly` 的 `JSESSIONID=<redacted>`」）。
3. **OHOS 差异**：与 Android/iOS 行为的偏离点（插件是否声明支持 OHOS、是否需 fork/打补丁）。
4. **环境**：OHOS 版本、Flutter-OHOS SDK 版本、候选包版本。
5. **最小复现步骤**：安装步骤 + 入口命令 + 操作序列（一两句即可）。探针执行与复核间隔可能很长（等设备 / 等人），留复现步骤让后续验证者能快速重跑。

---

## 6. go/no-go 决策

- **GO（WebView 主路线在 OHOS 成立）**：存在 ≥1 候选三项全 `pass`（或 `受限` 但条件可接受——「条件是否可接受」由**维护者拍板**，探针执行者只负责如实记录受限条件，不自行判定 go/no-go）。→ 回写 ADR-016 §2.4 锁定该候选，进收割实现。
- **NO-GO**：无候选满足 ①+②。→ WebView 主路线在 OHOS 不成立，回写 ADR-016：OHOS 上改走 headless 兜底，或评估 OHOS 原生 Web 组件自写桥接（新探针）。
- 无论结论，**产出回写 ADR-016 §2.4 + 关闭 issue #65**。

---

## 7. 合规边界（执行前必读）

- 探针属红线 #1 凭证收割路径：**AI 不得独自闭环**；探针代码 + 结论须人工主导 + 安全检查清单 + ≥1 人工审（AGENTS §1）。
- 凭证/cookie 永不离开可信核心；探针只验证「宿主能否把 cookie 交给核心」，不得把 cookie 写日志 / 提交仓库（红线 #1、#8）。
- 验证码**用户手解**，探针不引入自动绕过验证码的能力（合规面，见 ADR-016 §2.1）。
