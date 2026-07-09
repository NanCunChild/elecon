# ADR-017：CAS SSO 母凭证收割 + 静默签票（一次登录、按需换取下游 session）

- **状态**：已接受（Accepted）。本文服务红线 #1 的**凭证获取**路径（最高风险面），**扩大收割边界**（把 CAS 母凭证纳入核心库）并新增**核心侧静默换票能力**（触红线 #1、#5「adapter 不碰登录/凭证」、#10「架构性改动先写 ADR」）。本 ADR 由 AI 起草、经人工 + 安全检查清单审阅后接受（维护者 2026-07-09 补三点：母凭证非普适、单次授权退化、mint 机制下放 adapter——见 §2.1 / §2.5 / §2.6 与附录 A）；其**实现及测试**（收割、静默换票、Broker 注入母凭证、adapter mint 能力）仍须人工主导 + 安全清单 + ≥1 人工审（红线 #1，AI 不得独自闭环；[AGENTS.md](../../AGENTS.md) §1 + §10）。
- **日期**：2026-07-08
- **依赖**：[`adr_016_complex_login.md`](./adr_016_complex_login.md)（WebView 主路线 + 能力门禁，本文的静默换票是其 §2.1「登录动作」的一个受控子例）、[`adr_015_manifest_login.md`](./adr_015_manifest_login.md)（`login` 声明面——本文扩其成功检测/收割目标）、[`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md)（`credentials` 收割判据 b）、[`adr_012_credential_store.md`](./adr_012_credential_store.md)（§2.2 WebView 收割 + 凭证库）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（Broker 按 scope 注入，本文让 CASTGC 成为可注入 ref）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（能力门禁 official-only）
- **适用范围**：CAS 类单点登录的**母凭证（Ticket-Granting Cookie）收割** + **核心侧静默签票**（用母凭证换取任意下游服务 session，免用户重登）的**信任模型、数据流、声明面扩展**。以 XIDIAN IDS（Apereo CAS）为代表。**不含**：具体 WebView/headless 换票脚本逐校实现（落地 PR）、验证码求解（ADR-016 headless 面）、campus 中继取数（ADR-003）。

---

## 1. 背景（Context）

ADR-012/015/016 定下 WebView 登录主路径并已最小闭环（`feat/webview-login`：导航闭锁 + cookie 收割 → `decideHarvest` → `CredentialStore`）。但当前收割**只捞下游服务 session、漏了 CAS 母凭证**，导致「**一个服务一次登录**」——与「学生只登一次」的产品目标相悖，也没抓到 SSO 的本质。

**CAS 的本质**：XIDIAN IDS 是 Apereo CAS 单点登录。用户在 `ids.xidian.edu.cn/authserver/login` 认证成功后，CAS 在 **`ids.xidian.edu.cn` 域**种下 **`CASTGC`（Ticket-Granting Cookie，票据授予票）**。此后对**任意**服务 `S`：

```
GET https://ids.xidian.edu.cn/authserver/login?service=<S>   （携带 CASTGC）
  → 302  <S>?ticket=ST-xxxx      （CAS 见 TGC，直接签发一次性 service ticket）
  → <S> 校验 ST → Set-Cookie: <S 自己的 session> → 302 <S> 正常页
```

**全程无需再输密码 / 拖滑块**。即：`CASTGC` 是「母凭证」，各服务 session 是可随时按需换取的「子凭证」。

**当前缺口**（`client/lib/ui/settings/settings_page.dart` 的示例 manifest 视图）：

- `login.url` 写死 `?service=https://ehall...`——只对 ehall 签一次票；
- `credentials` 只声明 `ehall / v8scan / library` 三个**下游服务 scope**，**未声明 `ids.xidian.edu.cn` 的 CASTGC**；
- 收割判据 b（`decideHarvest`）因此**根本不收 CASTGC**——母凭证从未进核心库。

结果：想要一卡通/图书馆 session，只能改 `service=` 重登一次。**本质没抓到。**

---

## 2. 决策（Decision）

### 2.1 把 CASTGC 作为一等「母凭证」收割进核心库

**母凭证收割是可选优化，非普适前提。** 仅当学校 SSO 暴露**可复用、可从 cookie jar 收割**的母凭证（CAS TGC 类）时启用。学校无此设计、或采用**单次授权**（登录即消费、无母票可收割，§2.6）时，**不声明** `role: sso-master`，系统退化到逐服务可见登录（§2.6），与本 ADR 之前行为逐字节一致。启用时——`credentials` 增声明 CAS 母凭证 ref（示例 `ids-cas`），scope 覆盖 CAS 认证域：

```json
"credentials": {
  "ids-cas":      { "scope": ["https://ids.xidian.edu.cn/*"],   "type": "cookie", "role": "sso-master" },
  "ehall-session":{ "scope": ["https://ehall.xidian.edu.cn/*"], "type": "cookie" },
  "card-session": { "scope": ["https://v8scan.xidian.edu.cn/*"],"type": "cookie" }
}
```

- WebView 登录成功后，收割判据 b 会把 `ids.xidian.edu.cn` 下的 CASTGC 归入 `ids-cas` ref、写入 `CredentialStore`（复用现有 `decideHarvest` / `harvestInto`，**无需改收割核心**——只要声明面把 CAS 域列进某 ref 的 scope）。
- **红线 #1 不变**：CASTGC 只进核心库，**绝不交回 adapter / UI / 公网**。它比子 session 更敏感（能换任意服务票），故 §2.4 给它更严的注入边界。

### 2.2 核心侧「静默签票」能力（SSO mint）

新增一个**核心托管**的静默换票流程：给定目标服务 `S`（须在 manifest 声明的 SSO 服务白名单内），核心——

1. 由 Broker 决定对 `authserver/login?service=<S>` 注入 `ids-cas`（CASTGC）——**注入决策在核心，adapter 看不到值**；
2. 跟随 `?ticket=ST-…` 回跳链（**闭锁在 `login.navigationAllow` 内**，越界即断）；
3. 抵达 `S` 的成功 URL → 收割 `S` 的 session 进核心库（判据 b）；
4. 全程无 UI（或用**隐藏/离屏 WebView**）；失败（TGC 过期）→ **降级**到 §2.3 的可见 WebView 重登。

两种执行形态（落地阶段按 OHOS 真机与合规裁定，**本 ADR 不锁死**）：

- **(a) 隐藏 WebView 换票**：复用 ADR-016 WebView 栈，离屏加载换票 URL、靠导航闭锁与成功检测收割。合规最稳（无协议模拟），但需 OHOS 离屏 WebView 可行。
- **(b) headless 换票**：核心直接走 302 链（ADR-016 路线 B）。轻，但属协议模拟，且 CASTGC 注入的 HTTP 客户端须同样受 Broker 白名单闸门约束。

**mint 请求的构造机制下放到 adapter（official 能力）。** CAS 换票请求**校校异**：标准 Apereo 是 GET `?service=`，但有的学校走 **POST 表单**、ticket 在 **body** 内、参数名自定义，甚至需**从登录页动态取 form token / 对 body 签名**（如 XIDIAN 水电每请求签名，ADR-016 §1）。这条「自由面」无法静态穷举，故**下放到官方签名 adapter 的 mint 能力**（落 ADR-016 §2.2 同一条 official-only 门禁）：

- adapter 在沙箱内（背景 isolate，ADR-008）接收**非凭证输入**（登录页 DOM / service id / nonce），产出一个**请求描述符**（method、URL、静态 header、body 模板），凭证位置以**占位符**（如 `{{cred:ids-cas}}`）标记；
- **核心** Broker 按注入策略（§2.4）把母凭证填入占位符、**执行**请求、**跟随整条 ticket 回跳链**（ST 等中间票只在核心）、收割目标 session；
- adapter **全程拿不到**母凭证值、ST、Set-Cookie 或带票 URL（红线 #1「等价物」条款）——它只是**请求形状的作者**，核心才是**执行者 + 凭证托管者**（比 ADR-016 §2.3「登录动作执行者」更弱一层）。
- **已知边界**：若某校把凭证**嵌入 body 且纳入签名**，adapter 无法在不见凭证前提下算签名 → 此类校 mint 回退可见 WebView 或走核心侧签名钩子（落地再议，§4）。

> 静默换票**不是新信任档**：它是 ADR-016 §2.2「登录/收割」能力的受控子例，落**同一条 official-only-except-debug 能力门禁**。adapter 只**贡献请求构造逻辑**，不改变「凭证托管在核心」的边界。

### 2.3 首次登录仍走可见 WebView（不变）

母凭证的**获取**仍由用户在可见 WebView 手动完成（密码/滑块/2FA 用户自解，ADR-016 路线 A）。本 ADR 只新增「**已有母凭证后，子 session 静默换取**」。TGC 过期 → 回到可见 WebView 重新获取母凭证。

### 2.4 母凭证的注入边界（比子 session 更严）

CASTGC 能换任意服务票，是**高价值目标**。注入约束：

- **只允许注入到 CAS 认证端点**（`authserver/login` / `authserver/serviceValidate` 等 `ids.xidian.edu.cn` 路径），**不得**随子 session 一起注入到数据服务域。声明面上即：`ids-cas.scope` 仅含 `ids.xidian.edu.cn`，Broker 最长前缀匹配（ADR-009）天然不会把它注入到 `ehall` 等域。
- 静默换票的**执行与发起仅在核心**（SSO-mint 路径）；adapter 只**贡献请求构造逻辑**（§2.2 official 能力），**不发起 mint、不持凭证值、不见中间票**。adapter 最终只拿到子 session 的注入*结果*（且拿不到值）。
- 目标服务 `S` 须在 manifest 的 **SSO 服务白名单**（`login.ssoServices` 或复用 `credentials` 声明的下游 ref 集）内——**fail-closed**：未声明的 service 不换票，杜绝「拿 CASTGC 去换任意站点票」的横向扩张。

### 2.5 声明面扩展（ADR-015 增量，向后兼容）

`login` 块可选增 `ssoMint`，声明可静默换取的服务及其成功检测（缺省 = 不启用静默换票，退化为逐服务可见登录，与现状一致）：

```json
"login": {
  "url": "https://ids.xidian.edu.cn/authserver/login",
  "navigationAllow": ["https://ids.xidian.edu.cn/*", "https://ehall.xidian.edu.cn/*", "https://v8scan.xidian.edu.cn/*"],
  "success": { "whenUrlMatches": ["https://ehall.xidian.edu.cn/new/index.html*"] },
  "ssoMint": {
    "authEndpoint": "https://ids.xidian.edu.cn/authserver/login?service={service}",
    "services": {
      "card-session":    { "service": "https://v8scan.xidian.edu.cn/...", "success": ["https://v8scan.xidian.edu.cn/myaccount/*"] },
      "library-session": { "service": "https://hyytsgxzs.xidian.edu.cn/...", "success": ["https://hyytsgxzs.xidian.edu.cn/*"] }
    }
  }
}
```

**声明面只承载可静态验证的部分**（哪些服务、成功检测、导航边界、母凭证 ref）；**mint 请求的构造机制不进声明面**——简单 GET-redirect 情形由核心内置执行，非简单情形（POST/body/签名，§2.2）由 `ssoMint.services[*].via` 指向的 **adapter mint 能力**承载（`via` 缺省 = 内置 GET-redirect）。

校验规则（随落地）：

| # | 规则 | 级别 |
|---|---|---|
| M1 | `ssoMint.authEndpoint` 须 https 且落在 `navigationAllow` 内 | error |
| M2 | 每个 `ssoMint.services[*].service` 与其 `success` 均须 ⊆ `navigationAllow` | error |
| M3 | `ssoMint.services` 的键须存在于 `credentials`（换票产物有 ref 可收割）| error |
| M4 | 母凭证 ref（scope 覆盖 `authEndpoint` 域者）须存在且 scope **不**与任何下游数据域重叠（防母凭证外注入）| error |
| M5 | `services[*].via` 指定的 adapter mint 能力须 official 签名并声明 sso-mint 能力（sideload → 拒绝，release）| error |

### 2.6 无母凭证 / 单次授权：退化到逐服务可见登录（一等情形）

**并非所有学校都有母凭证设计**，也存在**单次授权**（one-shot：登录即消费、无可复用票）。这两类是**一等情形**，不是异常：

- **无 `sso-master` 声明**（学校无 TGC，或维护者未启用）→ 系统**不尝试静默 mint**；每个需鉴权服务在首次访问时弹**可见 WebView 登录**（ADR-016 路线 A，现状行为）。
- **单次授权**（授权登录即消费、无母票可收割）→ 同上退化；子 session 过期即重新可见登录。
- **母票失效**（§4.3）→ 静默 mint 未抵达成功 URL → 降级可见 WebView。

即：**可见逐服务登录是安全默认，母凭证静默 mint 是其上的可选优化**。声明面缺 `role: sso-master` / `login.ssoMint` 时，行为与本 ADR 之前完全一致——向后兼容、无回归。

---

## 3. 备选与取舍（Alternatives）

| 方案 | 取舍 | 裁定 |
|---|---|---|
| **A. 收割 CASTGC 母凭证 + 核心静默换票（本文选）** | 抓住 SSO 本质：一次登录换所有下游；母凭证进核心、注入受限于 CAS 端点；复用现有收割/注入核心，只扩声明面 + 加 SSO-mint 路径。 | **选用** |
| B. 维持逐服务可见登录（现状） | 最简、母凭证不落库（攻击面小）。**舍**：违背「学生只登一次」目标；多服务体验差；且没解决本质。 | 拒绝 |
| C. 收割各服务 session、但不收 CASTGC，靠各 session 各自续期 | 不落母凭证。**舍**：各服务 session 过期后仍须重登（无母凭证可静默续），治标不治本。 | 拒绝 |
| D. 把 CASTGC 交给 adapter，让 adapter 自己换票 | 最灵活。**舍**：触红线 #1/#5（adapter 持有母凭证 = 最严重的凭证外泄面）。 | 拒绝 |
| E. mint 机制**全静态**声明在 manifest（不下放 adapter）| 声明式、可验证。**舍**：无法穷举 POST/body/动态 token/签名等校异请求（§2.2），把过程性逻辑塞进声明面 = 变相 per-school 硬编码。 | 部分拒绝（简单 GET 情形保留声明式，复杂情形下放 adapter）|

---

## 4. 已知约束与风险（Consequences）

1. **母凭证是最高价值目标（红线 #1 最敏感面）。** CASTGC 能换任意服务票，一旦泄露 = 全线沦陷。**对策**：§2.4 注入边界（只进 CAS 端点、不随子 session 外注、SSO-mint 仅核心路径、服务白名单 fail-closed）；存储沿用 ADR-012 secure store；日志一律打码（现 `_maskCookie` 已覆盖）。
2. **静默换票的形态（隐藏 WebView vs headless）依赖 OHOS 真机。** 隐藏/离屏 WebView 在 OHOS（ArkWeb）可行性未验（ADR-016 §2.4 ③ 残留/隔离待真机）；headless 换票属协议模拟、合规灰度更高。**落地前须过 OHOS 探针 + 合规清单**，本 ADR 不锁死形态。
3. **TGC 生命周期 / 失效检测。** CASTGC 过期无显式信号，静默换票会 302 回登录页（而非目标服务）。须靠「换票未抵达成功 URL」判失效 → 降级可见 WebView 重登（§2.2 步 4）。与 ADR-009 §2.5「401-重登兜底」同范式。
4. **声明面扩展是契约改动（红线 #6）。** `login.ssoMint` + `credentials.role` 为**可选新增、向后兼容**；须随落地改 `contract/manifest.schema.json` + 校验器 M1–M5，并与 ADR-001/015 协调。
5. **母凭证 scope 与下游域必须不重叠（M4）。** 若声明失误让 `ids-cas.scope` 覆盖了数据域，Broker 可能把 CASTGC 注入数据请求 → 母凭证外泄。校验器 M4 静态拦，运行时 Broker 最长前缀 + fail-closed 再兜（红线 #1 纵深防御）。
6. **母凭证非普适，退化必须无回归（§2.1 / §2.6）。** 设计不得假设母凭证恒在；无 `sso-master` 时须与本 ADR 之前行为逐字节一致（可见逐服务登录）。落地须有「无母凭证 / 单次授权」回归夹具。
7. **adapter mint 能力是红线 #1 的新暴露点（§2.2）。** adapter 参与 mint 请求构造，须双重 enforce：① official-only 门禁（校验器 M5 + 运行时，类比 C3）；② 运行时确保 adapter **收不到**母凭证值 / ST / Set-Cookie / 带票 URL（红线 #1 等价物条款）——占位符填充与 ticket 回跳全在核心。debug 例外编译期剔除。
8. **body 内嵌 + 签名凭证是已知盲区（§2.2）。** 若凭证既入 body 又被签名，adapter 无法在不见值前提下算签名 → 此类校 mint 回退可见 WebView 或核心侧签名钩子（落地再议）。
9. **🔒 服务红线 #1 最高风险面 + 触红线 #5/#6/#10 + 合规。** 本 ADR 的接受、收割/静默换票/adapter mint/注入实现及其测试，按 AGENTS.md §1 不得 AI 独自闭环，须人工主导 + 安全清单 + ≥1 人工审。

---

## 5. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

- **先行**：确认 OHOS 隐藏/离屏 WebView 换票可行性（接 ADR-016 §2.4 ③ 真机探针）；无 WebView 场景（campus 中继）的 headless 换票合规评估。
- **契约面（PR-1）**：`credentials.role`（`sso-master`）+ `login.ssoMint` schema（含 `services[*].via`）；校验器 M1–M5；validator smoke 增 SSO-mint 用例。**纯新增、向后兼容。**
- **收割面（PR-2）**：manifest 把 CAS 域列入母凭证 ref（声明改动即可让现有 `decideHarvest` 收割 CASTGC）；补跨域收割夹具（母凭证 + 子 session 同轮收割）。
- **静默换票（PR-3，人工主导）**：核心 SSO-mint 路径（隐藏 WebView 或 headless）；**adapter mint 能力**（请求描述符 + 占位符，official-only 门禁 + M5 校验 + 运行时确保 adapter 不见凭证/ST/Set-Cookie/带票 URL）；Broker 允许母凭证注入 CAS 端点、拒绝外注；失效 / 无母凭证 / 单次授权均降级或退化到可见 WebView（须「无母凭证」回归夹具）。**红线 #1，AI 只起草，安全路径人工闭环。**
- **UI 面（PR-4）**：设置页「已登录 → 可用服务列表 / 按需授权」呈现；把写死在 `SettingsPage` 的 manifest 视图归位到 contract 声明面（ADR-015）。
- **交叉引用**：ADR-016 §2.1（静默换票 = 登录能力子例）、ADR-015 §2.1（`login` 增 `ssoMint`）、ADR-013（`credentials` 增 `role`）、ADR-009（母凭证注入边界）、ADR-000 §6 索引登记。

---

## 附录 A：修订记录

| 日期 | 版本 | 摘要 |
|---|---|---|
| 2026-07-08 | 草案 | 起草：把 CAS 母凭证 CASTGC 作为一等母凭证收割进核心库；核心侧静默签票（隐藏 WebView / headless）用母凭证按需换取下游 session，实现「一次登录、多服务免重登」；母凭证注入严格限于 CAS 端点 + 服务白名单 fail-closed（红线 #1）；声明面增 `login.ssoMint` + `credentials.role`（向后兼容）。拒绝维持逐服务登录 / adapter 持母凭证。**待人工 + 安全清单审。** |
| 2026-07-09 | 已接受 | 经人工审阅后接受，维护者补三点并折入：① **母凭证非普适**——收割是可选优化，无 `sso-master` 即退化（§2.1）；② **单次授权 / 无母票**列为一等退化情形，可见逐服务登录为安全默认、须无回归（§2.6 + §4.6）；③ **mint 请求机制（GET/POST/body/签名）下放到 official adapter**——adapter 产出请求描述符 + 凭证占位符、核心执行并托管凭证与中间票（§2.2 / §2.4 / §2.5 `via` + M5 / §4.7）。alternatives 增「全静态声明」部分拒绝（E）。实现仍按红线 #1 须人工主导。 |
