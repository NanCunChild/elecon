# ADR-016：复杂登录的 WebView 选型 + headless 路线（能力门禁，无新信任档）

- **状态**：已接受（Accepted）。本文服务红线 #1 的**凭证获取**路径（最高风险面），触红线 #5（登录非数据 adapter 的事）、#10（架构性改动先写 ADR），并涉验证码自动化的合规面。本 ADR 由 AI 起草、经人工 review 后接受；其**实现及测试**（能力门禁的校验器/运行时、WebView 与 headless 登录收割、OHOS 探针）仍须人工主导 + 安全检查清单 + ≥1 人工审（红线 #1，AI 不得独自闭环；[AGENTS.md](../../AGENTS.md) §1 + §10）。
- **日期**：2026-06-18
- **依赖**：[`adr_012_credential_store.md`](./adr_012_credential_store.md)（§2.2 核心托管 WebView 登录 + session 收割）、[`adr_015_manifest_login.md`](./adr_015_manifest_login.md)（manifest `login` 声明面）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（official/sideload 两档 + 红线 #5 dev 例外）、[`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md)（收割判据 b）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（注入消费收割结果）、[`adr_003_transport.md`](./adr_003_transport.md)（campus 中继 / 传输档）
- **适用范围**：复杂登录（CAS + 验证码类，以 XIDIAN 为代表）的**登录路线分档**（WebView / headless）、**信任与能力门禁模型**、**WebView 选型推进方式**。**不含**：具体 adapter 实现、WebView UI 像素级设计、headless 脚本逐校逻辑（落地 PR）。

---

## 1. 背景（Context）

XIDIAN 把复杂登录的全貌照清楚了（`adapters_tests/XIDIAN/` 已完整逆向）：

- **IDS（统一认证 CAS）**：AES 密码加密（salt 取自登录页，iv 固定）+ **滑块验证码**（脚本侧用 NCC 图像匹配 + 仿真鼠标轨迹自动求解）+ CAS 跨子域 ticket 链（`ids` → `ehall`）。
- 其上鉴权能力：成绩 / 课表 / 考试（ehall useApp）、一卡通（OAuth openid via `v8scan`）、图书馆（CAS → `hyytsgxzs` → `shuwo`）、**水电（`ignypt.xidian.edu.cn`，仅校园网内可达，请求体 AES + 每请求签名）**。

现状：XIDIAN **唯一生产可用**的是公开通知 `notice.list`（declarative，零凭证）；全部鉴权能力**已逆向验证可行但无一落地**，共同卡在「登录收割（拿到 session 进核心）」。ADR-012 §2.2 定了「核心托管 WebView 登录 → cookie jar 收割」主路径、ADR-015 定了 manifest `login` 声明面，但：① **WebView 选型未定**（包体积 / 平台一致性 / **OHOS 鸿蒙** / cookie jar 可取性）；② 水电这类**校园网内、服务端取数**场景没有 WebView 可弹，主路径覆盖不到。

核心矛盾：复杂登录既要**合规稳健、覆盖广**（→ WebView），又要能在**无 WebView 的服务端**跑（→ headless），且不能把 per-school 登录逻辑焊进核心二进制（ADR-000 §5.1 已舍弃编译期 per-school 定制）。

---

## 2. 决策（Decision）

### 2.1 两条互补登录路线

| 路线 | 形态 | 主用场景 | 验证码 |
|---|---|---|---|
| **(A) WebView 登录（主路线）** | 核心托管 WebView 加载学校真实登录页，从 cookie jar 收割 session（ADR-012 §2.2 / ADR-015 声明面） | 覆盖绝大多数学校；客户端 | **用户自解**（手拖滑块 / 2FA / SSO），零自动化、零合规风险 |
| **(B) headless 登录（选择性补充）** | 直接走协议（AES 密码 + 必要时验证码求解 + ticket 链），免 WebView | ① 无验证码或可平凡自动化的学校；② **campus 中继服务端**（如 XIDIAN 水电，校园网内、无 WebView） | 须自动求解或不需要 |

WebView 为默认主路线；headless **仅在上述两类场景**按需开启，不普适化。

### 2.2 信任与能力门禁：**不新增信任档**，按能力门禁

**沿用 ADR-002 的 official / sideload 两档，不为登录脚本新增信任档。** headless 登录与凭证收割不是「另一档信任的脚本」，而是**能力**——由**能力门禁**约束：

- **敏感能力 = DEPLOY official-only**：DEPLOY 无论 catalog / 本地来源都只运行 official；**DEV-Sideload 全能力例外**可调试下列能力，未签名 grant 路径不进入 DEPLOY。**敏感能力集**当前为：
  - **imperative requestGraph（带凭证注入的 `ctx.fetch`）** —— 见下方说明，这是门禁的**既有锚点**；
  - **登录**（触发核心托管 WebView / headless 登录流）；
  - **凭证收割**（从 WebView cookie jar / headless 握手结果收割 session 入核心）；
  - **headless 登录**（直接走协议的登录脚本，含验证码自动求解）。
- 校验器对敏感能力执行结构与引用规则；ADR-033 提议退役按 `trustTier: sideload` 一刀切拒绝的 C3/同类门禁，使 DEV 可完整预检和调试。DEPLOY 则在 official grant 与能力入口**双重 enforce**（不信任上游已校验，红线 #1 纵深防御）。
- **普通取数 capability** 可用 declarative 或 imperative；两者都可能由 broker 注入凭证，requestGraph 类型不等于“是否带凭证”。本节 official-only 门禁针对的是 imperative 自编排入口以及登录、收割、headless 等敏感能力；DEPLOY 本地来源同门禁，DEV-Sideload 可全能力调试。

**imperative 能力说明（门禁锚点）**：DEPLOY 的 official-only 由宿主验签 grant 与能力入口承担，本地导入不改变它；DEV-Sideload 则是全能力调试环境，可运行 imperative、登录、收割与 headless 登录。两者由编译期 profile 和不可伪造 grant 隔离，不以 declarative C3 代替运行时信任门。

**为何不新增信任档**：增一档 = 增概念面 + 维护面 + 全套签名/吊销/校验逻辑的再适配；而「能力门禁」复用现有 `trustTier` + capability registry + 校验器机制（且 imperative 已是先例），维护省、心智负担低（维护者 2026-06-18 拍板）。

### 2.3 凭证边界不变（红线 #1）

- WebView 与 headless **都只把收割到的 session 写入核心 `CredentialStore`**（ADR-012）；密码 / 验证码答案 / 中间 ticket **绝不交回 adapter / UI**。
- headless 脚本虽属 official 能力，**仍不得持有或回传凭证值**：登录产出（cookie/token）由核心收口，注入仍由 Broker 按 manifest 白名单决定（ADR-009）。headless 脚本是「登录动作的执行者」，不是「凭证的持有者」。
- headless per-school 逻辑**签名 + 可热替换**，不编进二进制（避 ADR-000 §5.1 编译期定制）。

### 2.4 WebView 选型：探针先行

- **先做 OHOS（鸿蒙）WebView 登录收割探针**（照 ADR-000 §5.2 / ADR-003 的「VPN 三件套探针」范式），结果回写本 ADR 再定选型。**OHOS 是 WebView 主路线的最大未知。**
- 倾向 `flutter_inappwebview`（`CookieManager` 可读 jar、`shouldOverrideUrlLoading` 做 `navigationAllow` 闭锁 + `success.whenUrlMatches` 检测、JS 注入可控、可用隔离 profile 并用后销毁）——契合收割/闭锁需求，但更重、**OHOS 支持待探针确认**。
- 备选 `webview_flutter`（官方、轻，但 cookie 提取 / 导航控制能力弱）。
- 探针验收标准见 §5 落地清单首项（探针）+ issue #65；探针规格 = [`docs/probes/probe_001_ohos_webview_harvest.md`](../probes/probe_001_ohos_webview_harvest.md)（go/no-go gate，结论回写本节）。
- **桌面调研结论（2026-06-19，[`probe_001_research_findings.md`](../probes/probe_001_research_findings.md)）**：OHOS = 自研 ArkWeb 引擎（非 AOSP WebView）。**选型确定 = `flutter_inappwebview`（OHOS 移植 `flutter_inappwebview_ohos`）**——`webview_flutter` OHOS 版高级 API 受限、不足以承载 CAS 拦截。三项能力桌面级：① cookie/HttpOnly 可读（C-API `getCookie(..., includeHttpOnly, ...)`）✅、② 导航闭锁可拦（锚 `onOverrideUrlLoading`，非 `onLoadIntercept`）✅、③ 隔离/销毁 ⚠️（OHOS 无目录级硬隔离，只能 `incognitoMode` 内存隔离，残留清除时序待真机）。**结论：WebView 主路线在 OHOS 倾向成立（GO-leaning），最终 go/no-go 待真机验证 ③。**

### 2.5 与 campus 中继对接

XIDIAN 水电（`ignypt.xidian.edu.cn`，校园网内）是 headless + campus 中继的现实落点：campus 中继（`server/src/campus`，现 stub，ADR-003）服务端无 WebView，须经 (B) headless 路线取数。headless 脚本的执行环境（客户端核心 vs campus 服务端）与凭证流向在落地 PR 与 ADR-003 接口一并定。

---

## 3. 备选与取舍（Alternatives）

| 方案 | 取舍 | 裁定 |
|---|---|---|
| **B. 能力门禁 official-only（本文选）** | 不动信任档；复用 tier+capability+validator；维护省。 | **选用** |
| A. 新增「登录脚本」高信任档 | 概念上把登录能力与数据 adapter 显式隔离。**舍**：增信任档 = 增概念/维护面，与精简主线相悖（维护者否决）。 | 拒绝 |
| C. headless 编进核心二进制 | 最直接。**舍**：per-school 登录逻辑进二进制 = ADR-000 §5.1 明确舍弃的编译期 per-school 定制，每改一校要发版。 | 拒绝 |
| D. 只 WebView、不做 headless | 最省、合规最稳。**舍**：水电等校园网内、服务端取数场景无 WebView 可弹，覆盖不到。 | 拒绝（headless 作选择性补充保留） |
| E. 让数据 adapter 自己登录 | **舍**：触红线 #5 / #1（ADR-012 已否决）。 | 拒绝 |

---

## 4. 已知约束与风险（Consequences）

1. **验证码自动化的合规面（headless 解滑块）。** headless 路线对 CAS+验证码学校须自动求解验证码（NCC + 仿真轨迹），属 anti-bot 规避的灰区。**对策**：headless 仅对**确有必要**的学校/场景开启（默认走 WebView 让用户自解）；自动求解逻辑文档化、可随时降级到 WebView；不把它作为普适默认。落地前须过合规清单。
2. **headless per-school 逻辑仍是维护负担。** 即便签名 + 热替换，逐校登录/验证码逻辑会随学校改版而碎。比编译期定制好（不发版即可推新脚本），但不消除维护面——故 §2.1 限定 headless 为选择性补充，不普适。
3. **OHOS WebView 可行性是主路线关键未知。** 若 OHOS 上 WebView 无法读 cookie jar 或拦导航，WebView 主路线在鸿蒙上不成立 → 须 headless 兜或另寻方案。**探针先行**（§2.4 / §5）。
4. **能力门禁须双重 enforce。** DEPLOY official-only 由静态能力规则 + 运行时不可伪造 grant 双重约束；catalog / 本地来源同门禁。DEV-Sideload 是全能力例外，未签名 grant 与 DEV 凭证放行路径须编译期不进入 DEPLOY。C3 退役不削弱这些运行时边界。
5. **🔒 服务红线 #1 最高风险面 + 触红线 #5 / #10 + 合规。** 本 ADR 的接受、能力门禁的校验器/运行时实现、WebView 与 headless 登录收割及其测试，按 AGENTS.md §1 不得 AI 独自闭环，须人工主导 + 安全清单 + ≥1 人工审。

---

## 5. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

- **先行探针**：OHOS WebView 登录收割可行性探针（独立 issue）。验收：OHOS 上 WebView 能否 ① 读 cookie jar 取 session、② 拦截导航实现 `navigationAllow` 闭锁 + `success.whenUrlMatches` 检测、③ 隔离 profile + 用后销毁。结果回写 §2.4 定选型。
- **能力门禁（校验器 + 运行时）**：注册敏感能力清单；校验器增「敏感能力 ⟹ official（release）」检查（类比 C3）；运行时双重 enforce；debug 例外编译期剔除。
- **WebView 登录收割**（ADR-012 §2.2 落地）：选定 WebView 包后实现导航闭锁 / 成功检测 / cookie 收割 → `decideHarvest`（B5）→ `CredentialStore`。
- **headless 路线**：headless 登录脚本的签名 + 热替换装载；执行环境（客户端核心 / campus 服务端）；与 ADR-003 transport / campus 中继接口对接（水电为首个标的）。
- **交叉引用**：ADR-002（能力门禁复用其 tier + 红线 #5 dev 例外）、ADR-012/015（声明面 + 收割）、ADR-003（campus）、ADR-000 §6 索引登记。

---

## 附录 A：修订记录

| 日期 | 版本 | 摘要 |
|---|---|---|
| 2026-06-18 | 草案 | 起草：复杂登录两路线（WebView 主 / headless 选择性补充）；**不新增信任档，按能力门禁**（敏感能力 official-only，debug 例外，类比红线 #5）；凭证边界不变（红线 #1）；WebView 选型先做 OHOS 收割探针。拒新增信任档 / headless 编进二进制 / adapter 自登录。 |
| 2026-06-18 | 已接受 | 经人工 review 后接受。§2.2 补 `fetch` 能力说明：带凭证注入是既有门禁锚点（现见 ADR-002 §2.5/§2.6、ADR-009 §2 决策 7），登录/收割/headless 纳入同一门禁。实现仍按红线 #1 须人工主导。 |
| 2026-06-19 | 已接受（§2.4 补桌面调研结论） | OHOS WebView 桌面调研产出（`probe_001_research_findings.md`）回写 §2.4：选型确定 `flutter_inappwebview`（OHOS 移植），能力 ①② 文档级确认、③ 待真机；WebView 主路线在 OHOS GO-leaning，最终 go/no-go 待真机 ③。不改决策主体，仅落实 §2.4「结论回写」。 |
