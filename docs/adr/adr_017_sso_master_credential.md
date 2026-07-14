# ADR-017：CAS SSO 母凭证收割 + 静默签票（一次登录、按需换取下游 session）

- **状态**：已接受（Accepted）。**rev-2（2026-07-14）已接受**并折入正文（§2.7 换票三级降级阶梯 + 平台能力门禁 / §2.8 body-签名盲区裁定 / §2.9「adapter 描述、核心决策」不变量 + official 能力边界扩展；默认排序定稿「少模拟优先」，见 §2.7；含维护者反馈，见附录 A 2026-07-14 两行）。本文服务红线 #1 的**凭证获取**路径（最高风险面），**扩大收割边界**（把 CAS 母凭证纳入核心库）并新增**核心侧静默换票能力**（触红线 #1、#5「adapter 不碰登录/凭证」、#10「架构性改动先写 ADR」）。本 ADR 由 AI 起草、经人工 + 安全检查清单审阅后接受（维护者 2026-07-09 补三点：母凭证非普适、单次授权退化、mint 机制下放 adapter——见 §2.1 / §2.5 / §2.6 与附录 A）；其**实现及测试**（收割、静默换票、Broker 注入母凭证、adapter mint 能力）仍须人工主导 + 安全清单 + ≥1 人工审（红线 #1，AI 不得独自闭环；[AGENTS.md](../../AGENTS.md) §1 + §10）。
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

> ✅ **§2.7 / §2.8 / §2.9 为 rev-2（2026-07-14），经维护者审阅后已接受**——收敛 §2.2 故意未锁死的**换票执行
> 形态**、明确 §2.2/§4.8 的 **body-内嵌签名盲区**裁定、立「adapter 描述、核心决策」不变量（§2.9）。其**实现及测试**
> 仍触契约声明面（红线 #6）与合规，按 AGENTS.md §1 须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环。

### 2.7 换票执行的三级降级阶梯 + 平台能力门禁（形态裁定，接 §2.2 未锁死项）

§2.2 把 headless(b) vs 隐藏 WebView(a) 留给落地裁定。本修订**不二选一**，而是按可用性排成**三级降级阶梯**，核心逐级尝试，**全程凭证托管在核心**（红线 #1 不变）：

1. **headless mint**（§2.2(b)，协议模拟）：核心直走 302 / 表单链。最省；对**协议漂移**（参数改名、新增 CSRF/nonce、加签名）脆弱——即「变动失效」。
2. **隐藏/离屏 WebView mint**（§2.2(a)，无协议模拟）：离屏加载换票 URL，靠导航闭锁 + 成功检测收割。对页面 / 协议形状变化**鲁棒**，仍静默无交互。
3. **可见 WebView 登录**（§2.3）：用户重认证（母票真过期 / 需 2FA / 滑块）。

**降级信号复用现状、不新增**：任一级 `classifyMintResult` 非 `success`（`tgcExpired` / `blockedOutsideNav`）→ 尝试下一级。**不在低级猜失败原因**（headless 黑盒分不清「形状漂移」与「母票过期」）——靠阶梯**自诊断**：隐藏 WebView 对形状漂移鲁棒，**若它也未达成功页，则非形状问题、即真过期 → 升可见登录**。这天然消歧，无需低级臆测。**自诊断是地板**（零 adapter 描述即可工作）；在其上，official adapter 可用**声明式判据**精化过期判定与升级决策（母票过期核心确难普适决策，见 §2.9 反馈 3/4）。

**成功检测三级同源**：一律走 manifest success-URL 匹配（`classifyMintResult` / `successMatches`）；**禁**以 HTTP 200 / cookie 出现判成功——中间步漂移会误判，收割权威只认成功页（红线 #1）。

**平台能力门禁（复用 ADR-016 能力门禁范式）**：阶梯的**可用级由平台运行时上报**——headless 恒可用；隐藏 / 离屏 WebView **仅在该平台离屏 WebView 可行时**可用。核心取 **(平台可用级) ∩ (manifest 允许级)** 按合规排序择优；**不得硬编码层级**——某平台无离屏 WebView → 阶梯坍缩为 headless → 可见登录，仍安全。

**OHOS 不阻塞本阶梯（收敛维护者反馈 2）**：Android 与 iOS **均支持全三级**，故三级阶梯**现在即在 Android/iOS 落地**，与 OHOS 无耦合。OHOS 当前**无真机**，一段时间内止步于**资料收集与讨论**（离屏/隐藏 WebView 于 ArkWeb 是否可行、探针 S1–S4）；待真机到位再按上述能力门禁接入——**无论 OHOS 是否支持隐藏 WebView，都不改变 Android/iOS 的三级行为**（OHOS 到位若只有 headless，则其阶梯坍缩为 headless→可见，安全默认不变）。原 §5「先行」中「OHOS 可行性确认」由**阶梯落地的阻塞前置**降为**并行的资料收集项**。

**合规排序策略（维护者 2026-07-14 定稿）**：headless 属协议模拟（合规灰度更高，§4.2）。曾并列两取向——省/快优先（headless 主）vs 少模拟优先（隐藏 WebView 主）。**裁定：默认「少模拟优先」**——隐藏 WebView 为默认主路径（合规最稳、与红线取向一致），headless 仅在**已验证站点**作加速优化按需开启。允许 manifest / 客户端策略按校、按平台覆盖此默认。

**声明面扩展（§2.5 增量，向后兼容）**：`login.ssoMint.services[*]` 可选增 `forms`（该 service 允许的 mint 形态白名单 + 可选偏好序）；缺省 = 全部平台可用形态、用客户端默认排序。可见登录（第 3 级）**恒为安全底**，`forms` 只约束 mint 级 (a)/(b) 的取舍，不能排除可见兜底。校验器新增：

| # | 规则 | 级别 |
|---|---|---|
| M6 | `ssoMint.services[*].forms`（若声明）须 ⊆ `{headless, hidden-webview}` 且非空 | error |
| M7 | `forms` 不得排除可见登录兜底（可见级恒为 §2.6 安全底；`forms` 仅裁 mint 级 a/b）| error |

### 2.8 body 内嵌且被签名的票据：裁定（接 §2.2 盲区 / §4.8）

§2.2 盲区：票据既进 body、又被学校对 body 算签名 → adapter 要算签名须见票据值 → 破「adapter 不见值」（红线 #1 等价物）。本修订裁定：

- **默认：回退可见 WebView 登录（§2.3）。** 不为此类校启用静默 mint——安全、零新暴露面、无回归（§2.6 安全默认逐字节适用）。**这是本次拍死的默认，维护者已同意。**
- **后续专项 ADR 按需求触发（收敛维护者反馈 1）**：是否新增「核心侧签名钩子」，**视此类学校的实际使用情况 / 出现频次而定**——**无实际需求则不建**。不为一个尚未出现的形态预先造机制。
- **核心膨胀警戒（收敛维护者反馈 1）**：用 adapter 承载「高度自定义」的请求 / 签名描述，若放任其表达任意过程逻辑，会把每校特例**灌进核心执行面**、致核心膨胀。故边界是：adapter 只给**声明式、封闭词表**的描述（body 模板 + `{{cred:…}}` 占位符 + **签名方案 id**）；签名方案本身是**封闭枚举**（如 `hmac-sha256(body)`、`xidian-hydropower-v1`），**绝非** adapter 任意代码（否则等于让 adapter 代码碰值的等价面，破红线 #1/#5，且核心须内建其执行器 = 膨胀）。这条边界正是「本次不建钩子」的另一理由：**没有封闭方案枚举之前，不开这道口**。若真要建：official-only（M5 同门禁）+ 方案实现随核心走人工 + 安全清单 + ≥1 人工审。

> 一句话：§2.8 与下 §2.9 同源——**能力增长发生在 official 描述的「封闭词表」里、经契约版本化；核心保持薄、不吞每校过程逻辑。**

### 2.9 「adapter 描述、核心决策」不变量 + official 能力边界的受控扩展（收敛反馈 1/3/4/5）

维护者反馈要把更多**每校知识**（母票过期判据、升级原因、mint 请求形状）交给 adapter。**可行**，但须守死一条不变量，否则同时踩两坑——红线 #1/#5（adapter 碰值 / 执行）与**核心膨胀**（每校过程逻辑塞进核心执行的描述符）：

> **不变量**：adapter 只**描述**（声明式数据、封闭词表——匹配条件、请求形状模板、方案 id）；**核心决策 + 执行**（持凭证值、跑控制流、编排阶梯）。adapter 永不见凭证 / 票据、永不执行换票或阶梯。

据此裁定三点：

- **母票过期判据（反馈 3）**：核心确难普适决策（各校过期表现不一——有的 302 回登录页、有的返 JSON `code`、有的换 200 错误页）。→ 允许 official adapter / manifest 给**声明式过期判据**（如 `expiredWhenUrlMatches` / `expiredWhenBodyMatches`），核心在**非凭证输入**（终点 URL、脱敏后标记）上求值分类。默认仍是 §2.7 的 URL 推断（未达成功页即疑过期）；描述符是**精化**、非取代。校验随落地：official-only + 仅对非凭证输入求值（不得引用 body 内凭证位）。
- **升级原因 + 前提条件（反馈 4）**：阶梯自诊断（§2.7）为**地板**；在其上，声明式判据可把结果分类为 `needs-user`（滑块 / 2FA 标记命中）/ `transient`（疑形状漂移）→ **有前提地短路**：`needs-user` **直升可见登录**（不浪费隐藏 WebView 级）、`transient` 走 headless→隐藏。**关键分界**：**「adapter *描述* 升级原因」可行**（声明式判据，核心据以决策）；**「adapter *处理 / 执行* 升级」不可行**（越红线——adapter 不跑阶梯控制流、不碰凭证）。用户原话「描述**或**处理」中，**只接受「描述」这一支**。
- **能力边界扩展（反馈 5）**：当声明式词表**表达不了**某校需求 → **扩 official adapter 的封闭词表**（新增声明式原语，official 签名 + 走 ADR / 契约改动，红线 #6 + 人工 / 安全审）——**而非**硬编码进核心（膨胀）、**也非**放宽侧载 adapter 权限（红线 #5，release 侧载恒为纯解析器）。增长发生在 official 描述词表、经契约版本化，**核心保持薄**。每次扩词表是一次可审查的契约演进，不是给 adapter 开自由执行面。

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

- **并行资料收集（非阻塞，rev-2 反馈 2）**：OHOS 隐藏/离屏 WebView 换票可行性（无真机→止于资料收集 + 讨论，接 ADR-016 §2.4 ③）；headless 换票合规评估。**不阻塞 Android/iOS 三级阶梯落地**（PR-5）。
- **契约面（PR-1）**：`credentials.role`（`sso-master`）+ `login.ssoMint` schema（含 `services[*].via`）；校验器 M1–M5；validator smoke 增 SSO-mint 用例。**纯新增、向后兼容。**
- **收割面（PR-2）**：manifest 把 CAS 域列入母凭证 ref（声明改动即可让现有 `decideHarvest` 收割 CASTGC）；补跨域收割夹具（母凭证 + 子 session 同轮收割）。
- **静默换票（PR-3，人工主导）**：核心 SSO-mint 路径（隐藏 WebView 或 headless）；**adapter mint 能力**（请求描述符 + 占位符，official-only 门禁 + M5 校验 + 运行时确保 adapter 不见凭证/ST/Set-Cookie/带票 URL）；Broker 允许母凭证注入 CAS 端点、拒绝外注；失效 / 无母凭证 / 单次授权均降级或退化到可见 WebView（须「无母凭证」回归夹具）。**红线 #1，AI 只起草，安全路径人工闭环。**
- **UI 面（PR-4）**：设置页「已登录 → 可用服务列表 / 按需授权」呈现；把写死在 `SettingsPage` 的 manifest 视图归位到 contract 声明面（ADR-015）。
- **降级阶梯（PR-5，rev-2 已接受，人工主导）**：三级阶梯编排（隐藏 WebView 主 → headless 优化 → 可见登录兜底，**默认「少模拟优先」§2.7 定稿；Android/iOS 先行、OHOS 解耦**）+ 平台能力上报接口 + `ssoMint.services[*].forms` schema（校验器 M6/M7）；阶梯自诊断为地板（低级非成功即升级、不猜原因）；**声明式过期 / 升级判据**（`expiredWhenUrlMatches` 等，official-only、仅非凭证输入求值，§2.9 反馈 3/4）——`needs-user` 短路直升可见、`transient` 走 headless→隐藏。补「headless 漂移 → 隐藏 WebView 兜住」「无离屏 WebView 平台坍缩」「声明式判据分类短路」回归夹具。**红线 #1，AI 只起草。**
- **body-签名钩子（PR-6，rev-2 圈定、需求触发、待专项 ADR）**：默认可见回退先落（无新面）；核心侧签名钩子**视此类学校实际出现情况**再定是否新增（§2.8 反馈 1，无需求不建），届时另开 ADR（封闭枚举方案 + official-only + adapter 只给方案 id）。
- **能力边界扩展原则（rev-2 §2.9 反馈 5）**：adapter 声明式词表遇边界 → 扩 official 封闭词表（official 签名 + 契约改动 + 人工/安全审），不硬编码进核心、不放宽侧载权限。每次扩词表 = 一次可审查契约演进。
- **交叉引用**：ADR-016 §2.1（静默换票 = 登录能力子例）、§2.2（能力门禁范式，rev-2 §2.7 复用）、ADR-015 §2.1（`login` 增 `ssoMint` + `forms`）、ADR-013（`credentials` 增 `role`）、ADR-009（母凭证注入边界）、ADR-000 §6 索引登记。

---

## 附录 A：修订记录

| 日期 | 版本 | 摘要 |
|---|---|---|
| 2026-07-08 | 草案 | 起草：把 CAS 母凭证 CASTGC 作为一等母凭证收割进核心库；核心侧静默签票（隐藏 WebView / headless）用母凭证按需换取下游 session，实现「一次登录、多服务免重登」；母凭证注入严格限于 CAS 端点 + 服务白名单 fail-closed（红线 #1）；声明面增 `login.ssoMint` + `credentials.role`（向后兼容）。拒绝维持逐服务登录 / adapter 持母凭证。**待人工 + 安全清单审。** |
| 2026-07-09 | 已接受 | 经人工审阅后接受，维护者补三点并折入：① **母凭证非普适**——收割是可选优化，无 `sso-master` 即退化（§2.1）；② **单次授权 / 无母票**列为一等退化情形，可见逐服务登录为安全默认、须无回归（§2.6 + §4.6）；③ **mint 请求机制（GET/POST/body/签名）下放到 official adapter**——adapter 产出请求描述符 + 凭证占位符、核心执行并托管凭证与中间票（§2.2 / §2.4 / §2.5 `via` + M5 / §4.7）。alternatives 增「全静态声明」部分拒绝（E）。实现仍按红线 #1 须人工主导。 |
| 2026-07-14 | rev-2 已接受 | **收敛 §2.2 未锁死的换票形态**：不二选一，改为**三级降级阶梯**（headless → 隐藏/离屏 WebView → 可见登录），复用 `MintOutcome` 降级信号 + 阶梯**自诊断**（低级非成功即升级、不猜原因）；成功检测三级同源（只认 success-URL）；**平台能力门禁**（复用 ADR-016 范式）令可用级由平台上报、`(平台∩manifest)` 择优、不硬编码层级（§2.7）。声明面增 `ssoMint.services[*].forms` + 校验器 M6/M7（可见级恒为安全底）。**合规排序为政策点**——草案建议默认「少模拟优先」（隐藏 WebView 主、headless 作已验证站点优化），**留维护者拍板**。**裁定 §2.2/§4.8 body-签名盲区**：默认回退可见登录（本次拍死）；核心侧签名钩子仅圈定约束（封闭枚举方案 + official-only + adapter 只给方案 id）、待专项 ADR，本次不实现（§2.8）。落地增 PR-5（阶梯）/ PR-6（签名钩子）。**AI 起草，未定；须人工审 + 安全清单 + 合规评估。** |
| 2026-07-14 | rev-2 · 维护者反馈折入（已接受）| 维护者审阅 rev-2 后五点折入并接受：① §2.8 body-签名默认「不启用静默 mint」**同意**，签名钩子改为**需求触发**（视此类校实际使用再定是否新增，无需求不建）；② **核心膨胀警戒**——高度自定义 adapter 描述不得表达任意过程逻辑，边界锁在声明式封闭词表（§2.8）；③ **OHOS 解耦**——无真机→止于资料收集/讨论，三级阶梯 **Android/iOS 先行**、不被 OHOS 阻塞（§2.7 + §5 先行降级为并行项）；④ **母票过期判据下放声明式 adapter 描述**（核心难普适决策，§2.9 反馈 3）；⑤ **升级前提 / 原因**——新增 §2.9 不变量「adapter 描述、核心决策」：接受「adapter *描述* 升级原因」（声明式判据短路 needs-user/transient）、拒绝「adapter *处理/执行* 升级」（越红线）；能力遇边界 → 扩 **official** 封闭词表（契约演进），不入核心、不放宽侧载。**§2.7 默认排序定稿为「少模拟优先」。** 实现及测试仍按红线 #1 须人工主导 + 安全清单 + ≥1 人工审。 |
