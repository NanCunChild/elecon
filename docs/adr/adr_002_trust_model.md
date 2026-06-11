# ADR-002：插件信任模型（签名 / 吊销 / dev 侧载闸门）与三档能力分级

- **状态**：**草案（Proposed）** ⚠️ 本文定义签名、吊销、信任分档与侧载闸门——触碰红线 #1/#4/#5 与可信核心承重路径，按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，**必须经人工 + 安全检查清单审阅后才可接受并实现**。
- **日期**：2026-06-11
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§2.2 可信核心、§3.3 凭证边界、§3.4 传输底座）、[`adr_001_contract.md`](./adr_001_contract.md)（§5.2 信任档字段，明确留给本文细化 community）
- **被依赖**：fetch 模式凭证注入 ADR（trust tier 由本文裁定）、传输底座 ADR（仅官方签名可加载）
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

- **是否官方签名** → 决定**能否进 release / 被分发**。签名（official 或 community 档）= 可经官方渠道分发；未签名 = 仅 dev 侧载。
- **信任档** → 决定**能做什么**（能力上限）。

| 档 | 建立方式 | 分发 | 能力上限 | 执行落点 |
|---|---|---|---|---|
| **official** | 一方编写或深度审查 + 项目签名 | release | **fetch 模式**（凭证注入资格）、可作为传输底座加载目标 | client-direct / campus-relay |
| **community** | 社区贡献 + 项目审查 + 项目**背书签名** | release | **仅 parser**（无凭证、无网络；核心代取+脱敏后喂原始响应） | 同 parser |
| **sideload** | 开发者本地加载，**无签名** | **仅 debug build** | **仅 parser**，且无网络/无凭证/无副作用 | 同 parser，dev 专用 |

能力呈单调阶梯：`sideload ⊆ community ⊆ official`。**凭证注入（fetch 模式）是 official 独占**——把最高风险面（红线 #1）锁死在一方授权的代码上；community 即便已签名可分发，默认仍是纯解析器笼子（红线 #5）。community → official 的提升需更重的审查 + 显式决策，不自动发生。

### 2.2 信任档由「签名背书」裁定，不信任 manifest 自报字段

manifest 里的 `trustTier` 只是**声明（claim）**，不是依据。**权威信任档来自核心对签名/背书的验证**：

- 一个侧载包把 `trustTier: "official"` 写进 manifest **不能**提权——核心验不到对应签名 → 一律按 sideload 处理（parser 笼子、debug-only）。
- 签名载荷**覆盖** `adapterId` + `adapterVersion` + 内容哈希 + **裁定档位**，使档位不可伪造。核心以"验签得到的档位"为准；与 manifest 自报不符则拒绝加载（fail-closed）。

### 2.3 签名机制

- **签什么**：adapter bundle 的规范化内容哈希（manifest + entry 源码 + 资产），detached 签名。传输底座二进制同理。
- **方案**：Ed25519 over SHA-256（待安全审阅敲定曲线/算法与规范化方式）。
- **密钥托管**：项目签名私钥离线 / CI secret / HSM，**绝不入仓**；对应公钥**pin 进客户端与服务端核心**。签名只在受控的 CI/release 环节发生，贡献者**不持私钥**。
- **校验**：核心在加载 official/community adapter 与传输底座**之前**验签，针对 pin 的公钥；验不过 → 拒绝（fail-closed）。`tools/src/signer` 产出签名，核心消费。

### 2.4 吊销（Revocation）

- **吊销清单**：签名的 revocation list（按 `adapterId` + 版本范围 / 具体 bundle 哈希），经**公网哑服务**分发（公开数据、零凭证，契合红线 #2）。
- **核心行为**：拉取 + 验签吊销清单，拒绝加载被吊销的 bundle；支持**最低版本下限**强制升级有漏洞的 adapter；支持密钥泄露时的总开关（kill-switch）。
- **时效与离线**：吊销清单自带新鲜度/TTL；拉取失败时回退到**上一份已验签的清单**（绝不把"拉不到"当成"全部放行"）。

### 2.5 dev 侧载闸门（红线 #4）

- 侧载加载路径**只编入 debug build**；release 二进制**没有**加载未签名 adapter 的代码路径。
- dev 传输底座同样**仅 debug build**存在（红线 #4）。
- 侧载 adapter 强制 parser 档：运行时给它的 ctx 就是 parser ctx（仅 `log`/`now`，**没有 fetch**，见 ADR-008 实现）——这是 capability-based 的硬约束，不靠"诚实声明"。

### 2.6 纵深防御：静态（tools）+ 运行时（core）

| 闸门 | 位置 | 职责 |
|---|---|---|
| 静态 | `tools/` 校验器（CI） | 拒 `sideload + fetch` 组合（ADR-001 §5.2）；白名单越界；parser 档源码静态检查（不得出现网络/凭证 API）；capability id 在注册表内 |
| 运行时 | 可信核心 | 验签（fail-closed）→ 查吊销 → 由签名裁定档位 → 按档发对应 ctx（仅 official 拿到带凭证的 fetch） |

即便侧载 adapter 谎称 official 或静态检查被绕过，运行时给非 official 档的 ctx **根本没有** fetch/凭证能力——提权在机制上不可能，而非靠君子协定。

---

## 3. 已知约束与风险（Consequences，草案）

1. **最高敏感路径（红线 #1/#4）。** 实现与测试**不得 AI 独自闭环**；需安全检查清单 + 人工审阅（git.md §3、testing.md）。
2. **密钥管理是单点。** 私钥泄露 = 信任根失守；需 kill-switch + 轮换预案 + 公钥可更新（但更新机制本身不能成为新的提权入口）。
3. **community 的审查负担。** "背书签名"意味着项目为 community adapter 的可分发性背书——审查深度与 PII/恶意行为筛查需配套流程（与红线 #8 夹具脱敏、`tools/scanner` 协同）。
4. **离线/陈旧吊销的可用性权衡。** fail-closed 与"拉不到清单时仍可用上次良好状态"之间需明确策略，避免吊销机制本身成为 DoS 面。
5. **签名规范化（canonicalization）易踩坑。** 哈希前的规范化若不稳定，会导致同一 bundle 验签飘移；需固定规范化规则并测试。
6. **与契约的边界。** 若需在 manifest 增签名/背书相关字段，属契约改动（红线 #6），另起 ADR 且向后兼容——本文不顺手改 schema。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

> 安全敏感项标 🔒（人工主导、AI 仅辅助）：

- 🔒 `tools/src/signer`：bundle 规范化 + 哈希 + Ed25519 签名 / 验签 + 吊销清单生成。
- 🔒 可信核心：加载前验签（fail-closed）+ 吊销查询 + 由签名裁定档位 + 按档发 ctx（official 才有带凭证 fetch）。客户端与服务端核心共享同一裁定逻辑。
- `tools/` 校验器：补 parser 档源码静态检查（无网络/凭证 API）；强化 `sideload + fetch` 拒绝（已在 ADR-001 列为闸门）。
- 侧载闸门：确保侧载加载路径**仅 debug build**编入；release 无入口（红线 #4）。
- 吊销分发：公网哑服务托管签名吊销清单；核心拉取/验签/回退策略。
- 测试：验签正/反例、谎报档位提权反例、吊销生效、规范化稳定性；安全敏感测试人工编写或实质审阅（testing.md §44）。
- 契约（如需，独立 ADR）：manifest 签名/背书字段，向后兼容。
