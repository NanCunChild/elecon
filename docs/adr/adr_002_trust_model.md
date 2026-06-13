# ADR-002：插件信任模型（签名 / 吊销 / dev 侧载闸门）与三档能力分级

- **状态**：**草案（Proposed）** ⚠️ 本文定义签名、吊销、信任分档与侧载闸门——触碰红线 #1/#4/#5 与可信核心承重路径，按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，**必须经人工 + 安全检查清单审阅后才可接受并实现**。
- **日期**：2026-06-11（**修订 2026-06-12**：补 §2.3 签名时档位来源与签名权、公钥轮换搭发版、§2.4 吊销 bootstrap、§2.1 community 取舍——回应人工复核 1–4）（**修订 2026-06-13**：**砍掉 community 档**（社区走 sideload、官方均 official）、§2.3 签名密钥改 **OIDC→AWS KMS 委托签名** + **多公钥预埋分批启用**、§2.5 release 编译期剔除侧载、§2.6 `ctx.fetch` 改"存在但档位校验"——落 #10 评审决策）
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§2.2 可信核心、§3.3 凭证边界、§3.4 传输底座）、[`adr_001_contract.md`](./adr_001_contract.md)（§5.2 信任档字段；community 策略原留给本文细化——本文**决定砍掉**，见 §2.1）
- **被依赖**：[`adr_009`](./adr_009_fetch_credential.md)（fetch 模式凭证注入，trust tier 由本文裁定）、[`adr_003`](./adr_003_transport.md)（传输底座抽象，仅官方签名可加载）；并为 [`adr_010`](./adr_010_ios_appstore.md) 的 App Store 合规论点 (b)「非代码市场」提供支撑（无侧载入口 + 仅签名分发）。
- **适用范围**：adapter（QuickJS 脚本）与传输底座（原生模块）的**信任建立、能力分档、分发与吊销**。**不含** 凭证注入的具体脱敏机制（另文）、UI 信任（不在此）。

---

## 1. 背景（Context）

ADR-000 §2.2 把"签名校验、吊销、dev 侧载闸门"定为可信核心的职责，§3.3/§3.4 给了三档能力分级与"传输底座仅官方签名"的方向，但没定**机制**。ADR-001 固定了 manifest `trustTier` 字段（official / community / sideload）并明确把 **community 策略与签名机制留给本文**。`tools/src/signer` 目前是 stub。

需要回答的核心问题：**凭什么相信一个 adapter？相信到什么程度（能拿凭证吗？能进 release 吗？）？怎么撤回信任？**

红线约束（承重墙，不可违背）：
- #1 凭证永不离核心 → 只有最高信任档才有资格触发凭证注入。
- #4 传输底座仅官方签名加载；release 无侧载入口；dev 传输仅 debug build。
- #5 第三方/侧载 adapter 必须是纯解析器（无网络/无凭证/无副作用）。

---

## 2. 决策（Decision，草案）

> 以下为**待审议**取向，非既定事实。每条都需安全审阅确认。

### 2.1 两个正交维度：签名管「分发」，信任档管「能力」

把两件常被混为一谈的事拆开：

- **是否官方签名** → 决定**能否进 release / 被分发**。official 签名 = 可经官方渠道分发；未签名 = 仅 dev 侧载。
- **信任档** → 决定**能做什么**（能力上限）。

| 档 | 建立方式 | 分发 | 能力上限 | 执行落点 |
|---|---|---|---|---|
| **official** | 一方编写或深度审查 + 项目签名 | release | **fetch 模式**（凭证注入资格）、可作为传输底座加载目标 | client-direct / campus-relay |
| **sideload** | 开发者本地加载，**无签名** | **仅 debug build** | **仅 parser**，且无网络/无凭证/无副作用 | 同 parser，dev 专用 |

能力呈单调阶梯：`sideload ⊆ official`。**凭证注入（fetch 模式）是 official 独占**——把最高风险面（红线 #1）锁死在一方授权的代码上。

**community 档已砍（2026-06-13 决定）**：原拟的 community 与 sideload 能力上限相同（都 parser-only），背书签名只买到「能经官方渠道分发」，代价却是**维护者须逐个审查并背书**——正是 ADR-000 要消除的人工瓶颈。权衡后**取消 community 档**：信任模型只剩 **official** 与 **sideload** 两档。社区贡献的 adapter 一律走 **sideload**（贡献者自行 debug 加载，或经审查被收编为 official）；**官方维护 / 深度审查的 adapter 一律 official**。这把维护者从"为可分发性背书"的责任里解放出来，与「最小人力」主线对齐。代价：**没有"已签名可分发但仍由社区维护"的中间态**——可分发即官方背书。manifest `trustTier` 的 `community` 取值由此成为**保留位 / 不启用**：核心**无 community 验证路径**，任何自报 community 的包按 sideload 处理（§2.2）；枚举值的契约清理另起 ADR-001 协调（红线 #6），本文不改 schema。

### 2.2 信任档由「签名背书」裁定，不信任 manifest 自报字段

manifest 里的 `trustTier` 只是**声明（claim）**，不是依据。**权威信任档来自核心对签名/背书的验证**：

- 一个侧载包把 `trustTier: "official"` 写进 manifest **不能**提权——核心验不到对应签名 → 一律按 sideload 处理（parser 笼子、debug-only）。
- 签名载荷**覆盖** `adapterId` + `adapterVersion` + 内容哈希 + **裁定档位**（两档制下即 official；无签名 = sideload），使档位不可伪造。核心以"验签得到的档位"为准；与 manifest 自报不符则拒绝加载（fail-closed）。

### 2.3 签名机制

- **签什么**：adapter bundle 的规范化内容哈希（manifest + entry 源码 + 资产）+ **裁定档位**（§2.2），detached 签名。传输底座二进制同理。
- **方案**：**Ed25519**（RFC 8032）签名 over bundle 内容摘要。注意 **Ed25519 内建哈希固定为 SHA-512、不可参数化**——所以"Ed25519 over SHA-256"是范畴错误；这里的 **SHA-256 仅指 bundle 内容摘要**（签什么），与 Ed25519 内部的 SHA-512（怎么签）是两处独立的哈希。规范化方式待安全审阅敲定。
- **签名时的档位来源 = 真正的信任根（不可含糊）。** §2.2 说「档位进签名载荷」，那么*签名那一刻*档位从哪来、谁有权签 official，才是整套机制的信任根，必须显式定，不能甩给"CI/release"四个字：
  - **档位不取自待签 bundle 的 manifest 自报**（那是 claim），而由**签名流程的显式决策**注入——即「签 official」是一个**需显式批准的动作**，由项目维护者（release owner）执行。
  - **签名密钥托管：OIDC → 云 KMS 委托签名（初选 AWS KMS）。** official 私钥托管于 **AWS KMS / HSM**，**永不导出、绝不入仓、不以裸 GitHub secret 存放**。CI 经 **GitHub OIDC** 取得**短时效**联合身份后，向 KMS 请求**单次签名操作**（拿到的是签名结果，不是密钥）。这把「official 签名权」与「日常 CI 改动权」从**机制层**分离——能改 workflow ≠ 能拿到密钥；即便某次 CI run 被供应链投毒，也只能在持短 token 的窗口内请求有限签名，**偷不走密钥**。本仓库保持 private、开源走另一独立仓库只是**纵深防御的一层**，不替代密钥托管。
  - **KMS 侧加固**：访问策略限定「仅受保护 tag / release workflow + 带 required reviewer 的 GitHub Environment」可触发签名 → 找回上一条要的**人工批准闸门**；KMS 自带**每次签名审计日志 + 速率限制 + 即时撤销访问**（密钥层 kill-switch）。
  - **现状 / 过渡**：AWS 托管**尚未 provision**，作为下一步方向（#10）。KMS 接通前的过渡期，至少走「受保护 Environment + release required reviewer + 仅 tag 触发」的长期 secret 方案，配合 §2.4 吊销 / kill-switch 兜底。
  - 贡献者**不持任何私钥**。
- **公钥托管：多公钥预埋 + 分批启用（缓解丢失/泄漏），密钥集合仍随发版变更。** 核心**预埋一组**公钥（pin 进客户端与服务端），而非单把——含 **1 把 active 签名公钥 + 若干 dormant 备用公钥**：
  - **应对私钥丢失**：active 私钥若不可用，**晋升**一把已预埋的备用公钥接替——其公钥已随上次发版下发，无需为"引进新信任根"打紧急发版。
  - **应对私钥泄漏**：对泄漏密钥的**停用 / 吊销走已有签名吊销通道**（§2.4），方向是**收窄信任**（fail toward less trust），可半热生效。
  - **方向不对称（安全要点）**：**收窄信任（停用/吊销）可半热**；**放大信任（启用/晋升一把此前 dormant 的公钥）必须保守**——优先随发版，或经**带新鲜度上限的签名启用声明**，因为这是危险方向。
  - **关键不变量**：可被启用的公钥**只能来自已预埋集合**——任何下发信号都无法引入"不在二进制里"的新公钥，§3.2 警告的"更新通道变新信任根入口"因此被**封死在预埋集合内**。增删**整个预埋集合**仍**一律随 App 发版**（与 [`adr_010`](./adr_010_ios_appstore.md)「信任根变更只能随发版」同构，钉在应用商店审核之后）。
- **校验**：核心在加载 official adapter 与传输底座**之前**验签，针对当前 **active** 的 pin 公钥；验不过 → 拒绝（fail-closed）。`tools/src/signer`（经 OIDC→KMS）产出签名，核心消费。

### 2.4 吊销（Revocation）

- **吊销清单**：签名的 revocation list（按 `adapterId` + 版本范围 / 具体 bundle 哈希），经**公网哑服务**分发（公开数据、零凭证，契合红线 #2）。
- **核心行为**：拉取 + 验签吊销清单，拒绝加载被吊销的 bundle；支持**最低版本下限**强制升级有漏洞的 adapter；支持密钥泄露时的总开关（kill-switch）。
- **时效与离线**：吊销清单自带新鲜度/TTL；拉取失败时回退到**上一份已验签的清单**（绝不把"拉不到"当成"全部放行"）。
- **首次启动 / 全新安装的 bootstrap（消解 fail-closed 的两难）。** "回退到上一份已验签清单"在全新安装、**尚无 last-good** 时无依据，会陷入「fail-open 不安全 / fail-closed 离线即不可用」两难。对策：**App bundle 内预置一份初始的已签名吊销清单**（随发版更新），作为 last-good 的初值——新装即有一份可信基线，离线也能 fail-closed 而不瘫。这与 [`adr_010`](./adr_010_ios_appstore.md) §2.2「bundle 预置基线 adapter」同源：让 App 在零网络下即自包含可用。预置清单只是**下限**，联网后按 TTL 拉取更新。

### 2.5 dev 侧载闸门（红线 #4）

- 侧载加载路径**在编译阶段即从 release 剔除**——不是运行时开关，而是 release 二进制里**根本不存在**加载未签名 adapter 的代码（编译期 `kReleaseMode` / 条件编译裁掉整段）。dev build 的侧载形态另议。
- dev 传输底座同样**仅 debug build**存在（红线 #4）。
- 侧载 adapter 强制 parser 能力：其 `ctx.fetch` 虽**存在**，但调用时被**档位校验拒绝**（§2.6）——返回结构化权限错误而非凭证注入；凭证注入的真实能力（宿主网络 + 注入）对非 official **在宿主边界 fail-closed**，是 capability-based 的硬约束，不靠"诚实声明"。

### 2.6 纵深防御：静态（tools）+ 运行时（core）

| 闸门 | 位置 | 职责 |
|---|---|---|
| 静态 | `tools/` 校验器（CI） | 拒 `sideload + fetch` 组合（ADR-001 §5.2）；白名单越界；parser 档源码静态检查（不得出现网络/凭证 API）；capability id 在注册表内 |
| 运行时 | 可信核心 | 验签（fail-closed）→ 查吊销 → 由签名裁定档位 → `ctx.fetch` 对所有档**存在**，但调用时按"宿主裁定的档位"校验：非 official 得到**结构化权限错误**（非 `TypeError`、非静默），且**永不触达凭证注入路径** |

**`ctx.fetch` 的形态（2026-06-13 调整）**：`ctx.fetch` 对所有档**一律存在**——目的是让非 official 调用时拿到清晰的「权限不足」错误，而不是晦涩的 `ctx.fetch is not a function`（`TypeError`）。但这**不削弱** capability-based 保证：
- **档位由宿主据验签结果裁定**（非 adapter 自报），校验**在宿主边界 fail-closed**。
- 非 official 的 `ctx.fetch` 调用在拿到**任何**网络/凭证能力**之前**即被拒——被守的不是"错误提示"，而是**宿主侧的网络出口与凭证注入**，二者对非 official 物理不可达。
- 因此即便侧载 adapter 谎称 official、或静态检查被绕过，提权仍在机制上不可能；变的只是**错误形态（权限错误 vs `TypeError`）**，不变的是**非 official 永不触达凭证注入**。

---

## 3. 已知约束与风险（Consequences，草案）

1. **最高敏感路径（红线 #1/#4）。** 实现与测试**不得 AI 独自闭环**；需安全检查清单 + 人工审阅（git.md §3、testing.md）。
2. **密钥管理是单点，已多重缓解。** 私钥泄露 = 信任根失守。缓解：① 私钥托管 **AWS KMS / HSM、永不导出、OIDC 短时委托签名**（§2.3）——失陷面从"偷走密钥"降为"窃取短 token 窗口内的有限签名 + KMS 审计可溯 + 即时撤销"；② **多公钥预埋 + 分批启用**（§2.3）应对丢失（晋升备用）与泄漏（吊销收窄）；③ kill-switch（§2.4）。残余风险：放大信任方向（启用新公钥）仍受发版/审核节奏制约，急性事件靠 kill-switch + 吊销兜。
3. **community 档已砍（§2.1）。** 信任模型简化为 **official + sideload** 两档，维护者不再为"可分发性"背书，去掉了审查瓶颈。代价：社区贡献者要么自行 debug 侧载、要么经审查被收编为 official，**没有"已签名可分发但仍由社区维护"的中间态**。残余项：manifest `trustTier` 枚举的 `community` 值清理须另起 ADR-001 协调（红线 #6）；`tools/scanner` 的 PII/危险 API 静态筛查仍对"收编 official 前的审查"有用，保留。
4. **离线/陈旧吊销的可用性权衡。** fail-closed 与"拉不到清单时仍可用上次良好状态"之间的策略已在 §2.4 定调（last-good 回退 + bundle 预置初始清单解全新安装的两难），避免吊销机制本身成为 DoS 面。残余权衡：预置清单的新鲜度受发版节奏限制，急性吊销仍依赖联网拉取 + kill-switch。
5. **签名规范化（canonicalization）易踩坑。** 哈希前的规范化若不稳定，会导致同一 bundle 验签飘移；需固定规范化规则并测试。
6. **与契约的边界。** 若需在 manifest 增签名/背书相关字段、或清理 `trustTier` 的 `community` 枚举值，属契约改动（红线 #6），另起 ADR 且向后兼容——本文不顺手改 schema。
7. **`ctx.fetch`"存在但档位校验"需下游一致性更新（§2.6）。** 此取向改了运行时 ctx 形态——[`adr_009`](./adr_009_fetch_credential.md) §2.6「非 official 退化为 parser」、[`adr_008`](./adr_008_client_runtime.md) 客户端运行时、以及**现有 parser ctx 实现**（`server/src/runtime/sandbox.ts` 的 `buildParserCtx` 与 `client/lib/core/adapter_runtime.dart` 的 bootstrap 目前只给 `log`/`now`、无 `fetch`）都需同步为"`ctx.fetch` 存在但宿主边界 fail-closed 拒绝非 official"。**安全不变量不变**（非 official 不可达凭证注入），变的只是**错误形态**（权限错误 vs `TypeError`）。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

> 安全敏感项标 🔒（人工主导、AI 仅辅助）：

- 🔒 `tools/src/signer`：bundle 规范化 + 内容摘要（SHA-256）+ **Ed25519 签名经 OIDC→AWS KMS 委托**（私钥不入仓）/ 验签 + 吊销清单生成。
- 🔒 **OIDC→KMS 签名管线**：GitHub OIDC 联合身份 → AWS KMS 单次签名；访问策略限定受保护 tag/release workflow + required-reviewer Environment。过渡期降级为受保护 Environment 长期 secret。
- 🔒 可信核心：加载前验签（fail-closed，针对 active 预埋公钥）+ 吊销查询 + 由签名裁定档位 + `ctx.fetch` 档位校验（非 official → 结构化权限错误、永不触达注入）。客户端与服务端核心共享同一裁定逻辑。
- 🔒 **多公钥预埋 + 分批启用**：active/dormant 公钥集合；晋升（应对丢失）/ 停用（应对泄漏）方向不对称（§2.3）；集合增删随发版。
- `tools/` 校验器：补 parser 能力源码静态检查（无网络/凭证 API）；强化 `sideload + fetch` 拒绝（已在 ADR-001 列为闸门）。
- 侧载闸门：确保侧载加载路径**编译期从 release 剔除**（非运行时开关）；dev build 另议（红线 #4）。
- 吊销分发：公网哑服务托管签名吊销清单；核心拉取/验签/回退策略。
- 测试：验签正/反例、谎报档位提权反例、`ctx.fetch` 非 official 拒绝（权限错误而非 TypeError 且不触达注入）、公钥晋升/停用、吊销生效、规范化稳定性；安全敏感测试人工编写或实质审阅（testing.md §44）。
- 契约（如需，独立 ADR）：manifest 签名字段、`trustTier` 枚举 `community` 清理，向后兼容。
