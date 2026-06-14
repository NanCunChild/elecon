# ADR-012：凭证获取（登录）与可信核心凭证存储

- **状态**：**草案（Proposed）** ⚠️ 本文触碰红线 #1（凭证）的**最高风险面**——凭证从哪来、存哪、什么形态。按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，**必须经人工 + 安全检查清单审阅后才可接受并实现**。
- **日期**：2026-06-13（**修订 2026-06-14**：① §2.2 增 fetch 模式握手的耐久 session 收割——与 WebView 登录同一动作、判据 = manifest 声明的 credential ref（判据 b），与 [`adr_009`](./adr_009_fetch_credential.md) §2.4 / [`adr_013`](./adr_013_manifest_credentials.md) 协调；② §2.4 闭合 scope/type 双源——store 保留为防御性副本+一致性基准，注入权威唯一在已验签 manifest，不一致以 manifest 为准并告警；③ §2.6 钉定首版仅 client-direct，relay 凭证落点推迟、本 ADR 不依赖 relay，relay 须满足"零落盘+用完即弃/客户端注入"硬约束）
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§3.3 凭证边界、§2.2 可信核心）、[`adr_001_contract.md`](./adr_001_contract.md)（manifest / 契约）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（谁有资格用凭证 = official）、[`adr_003_transport.md`](./adr_003_transport.md)（campus-relay 落点）、[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（客户端核心）
- **被依赖**：[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（其 §2.3 的 "credential reference" 正是指向本文定义的凭证条目；其注入消费本文的存储）
- **相关 issue**：[#3](https://github.com/NanCunChild/elecon/issues/3)、[#17](https://github.com/NanCunChild/elecon/issues/17)；本文回应 #8/#10 评审指出的"**凭证存储 + 登录获取孤儿缺口**"。
- **适用范围**：凭证如何被**获取**（登录）、如何在**可信核心**存储与做生命周期管理、credential reference 的**数据形态**。**不含**：凭证如何注入出站请求（[`adr_009`](./adr_009_fetch_credential.md)）、谁有资格用（[`adr_002`](./adr_002_trust_model.md)）、传输底座本身（[`adr_003`](./adr_003_transport.md)）。

---

## 1. 背景（Context）

ADR-005/008 的 parser 模式靠"核心代取 + 脱敏 → adapter 纯解析"。但"**代取**"这一步本身就需要凭证——而当前核心**没有任何凭证获取/存储机制**：客户端未接入任何安全存储，`server/src/campus` 是 stub（"尚未实现"）。

ADR-009 假定"按 reference 注入凭证"，ADR-002 假定"official 才有凭证注入资格"，但**凭证从哪来、存哪、是什么数据形态**——两者都没认领。这是 fetch 模式（乃至 parser 模式代取）真正的**地基**。#8 与 #10 的评审都把它点成了悬空缺口。

红线约束：
- #1 凭证（值与任何等价物）永不离开可信核心。
- #2 公网哑服务零凭证、无状态。
- #3 私密数据只走 client-direct 或 campus-relay。

**核心难题（本文要解的张力）**：登录流程**高度校校异**——端点、CSRF、验证码、2FA、SSO 跳转、JS 挑战各不相同，天然像"需要一段 per-school 代码"；但红线 #1 + #5 要求**凭证绝不经过 adapter**（adapter 必须是无凭证的纯解析器）。**如何在不让 adapter 碰凭证的前提下完成校异登录？**

---

## 2. 决策（Decision，草案）

> 以下为**待审议**取向，非既定事实。每条都需安全审阅确认。

### 2.1 凭证只存于可信核心，客户端是权威存储（canonical store）

凭证以**设备本地 OS 安全存储**加密落盘：iOS Keychain / Android Keystore / 桌面 Secret Service（libsecret/keyring）。adapter、UI 层、公网服务端**永不**持有（红线 #1/#2）。存储抽象统一封装，向上只暴露"按 ref 取/存/删"，不暴露明文。

### 2.2 登录主路径：「核心托管 WebView」——把校异与人机交互外包给学校登录页

不自己模拟每所学校的登录请求，而是：

1. 核心打开一个**核心控制的 WebView**，加载学校**真实登录页**（URL 由 official manifest 声明，受 ADR-002 签名约束）。
2. 用户在**学校自己的页面**输入账号密码——凭证进的是学校页面，**不经过 adapter，甚至不必进核心的字段存储**。
3. 登录成功后，核心从 WebView 的 cookie jar / 存储中**收割 session 凭证**（cookie / token），存入 §2.1 安全存储。**核心收割的是登录结果（session），不强制持有原始口令**——进一步缩小红线 #1 暴露面。

   > **同一收割动作也服务 fetch 模式握手（2026-06-14，与 [`adr_009`](./adr_009_fetch_credential.md) §2.4 协调）**：fetch 模式 adapter 经 `ctx.fetch` 完成多步反爬/握手后，origin 下发的**耐久 session cookie** 同样在执行结束时由核心收割进本存储——触发点从"WebView 登录页"扩展到"fetch 握手结束"，但收割逻辑、安全边界、`CredentialEntry` 形态一致。**收割判据 = manifest `credentials.<name>` 显式声明的 ref（判据 b）**，未声明者一律丢弃（不持久化），封死"诱导 origin 下发任意 cookie 入库"的面。adapter 全程不可见值。
4. WebView 是**核心代码、非 adapter**；其中跑的是学校页面的 JS，在隔离 WebView 内，**不接触 adapter 运行时、不接触其它学校的凭证**。

**为什么 WebView 而非"核心 headless 模拟登录"**：验证码、2FA、SSO 联合登录、JS 反爬挑战这些**人机交互/反爬**用 headless 请求几乎不可维护（正是 ADR-009 §3.4 主动划走的"JS 挑战"领域）。WebView 让学校页面自己处理这些，核心只取最终 session——**最大兼容 + 最少维护**，与项目"对接口变动保持韧性、最小人力"的主线一致。

### 2.3 可选「声明式刷新配方」用于无人值守续期，不用于首次获取

对支持的学校，manifest 可声明一份**纯数据**的 token 刷新流程（端点、字段映射、token 提取规则）。核心据此用已存的长效凭证换新 session：

- **全程在核心、配方是数据非代码**；凭证值由核心填充，配方步骤**看不到**凭证明文。
- 仅用于**续期**；首次登录 / 会话整体失效一律回落到 §2.2 的 WebView。
- 纳入 manifest = 契约改动（红线 #6），须独立协调 ADR-001、向后兼容——**不在本文落 schema**。

### 2.4 `CredentialEntry` 数据形态（供 ADR-009 注入消费）

```
CredentialEntry {
  ref:        string                 // 稳定引用名；manifest credentials.<name> 指向它（ADR-013）
  schoolId:   string
  type:       "cookie" | "header"    // 注入方式（防御性副本，权威在 manifest，见下）
  scope:      string[]               // URL 前缀（防御性副本，权威在 manifest，见下）
  value:      <encrypted-at-rest>    // 仅在注入瞬间于核心内解密，用完即弃，永不出核心
  acquiredAt: epochMs
  expiresAt:  epochMs | null
  status:     "active" | "expired" | "revoked"
}
```

- `value` 在安全存储内加密；broker 在 ADR-009 §2.1 的 step 2（注入）瞬间解密、用毕立刻丢弃。
- `ref` 即 manifest `credentials.<name>`（[`adr_013`](./adr_013_manifest_credentials.md)）的**指向目标**——本文与 ADR-009 的边界由此闭合：**ADR-012 定义凭证条目，ADR-009 定义如何注入它，ADR-013 定义 manifest 如何声明它**。
- **`scope` / `type` 的权威归属（2026-06-14 决策，闭合 ADR-013 §2.2 的协调项）**：注入决策（是否注入、注入哪个、注入到哪些 URL）**以已验签 manifest 的 `credentials.<name>` 为唯一权威**——manifest 经官方签名（ADR-002 §2.3），不可被运行时数据篡改。`CredentialEntry` 内保留 `scope` / `type`，作用是**防御性副本 + 一致性校验基准**，**不**作为注入依据。store 副本与 manifest 不一致时，**以 manifest 为准并告警**（疑似 store 污染或 adapter 升级后 scope 漂移）。`value` 是唯一只存在于 store、绝不进 manifest 的字段（红线 #1）。

### 2.5 生命周期与撤销

- **过期**：`expiresAt` 到期，或请求返回 401 / 302→登录页 → 标 `expired`，触发 §2.3 续期或 §2.2 重新登录。
- **用户登出 = 立即抹除**：从安全存储**删除**该 entry（不只是标记），并清空对应 WebView cookie jar。
- **吊销联动**：ADR-002 的 kill-switch 触发、或 adapter 被吊销时，关联凭证一并失效。

### 2.6 首版范围与 campus-relay 的凭证落点边界

**首版范围（2026-06-14 决策）：仅 `client-direct`。** campus-relay 的凭证传输方案**推迟**至 relay 本身（[`adr_003`](./adr_003_transport.md)）被接受并进入实现时再定。**本 ADR 的接受与实现不依赖 relay 设计的完成**——凭证存储 + WebView 登录收割（§2.1/§2.2）是 client-direct 的地基，可独立落地，不被 relay 阻塞。

**relay 凭证边界须满足的不变量（在此声明为约束，细节由后续 ADR-003/009 协调时补全）**：

- 客户端始终是**权威存储**；relay 执行时**零落盘**——不持久化任何凭证（否则 relay 变凭证蜜罐，违背红线 #1/#2 精神）。
- 凭证在 relay 侧**单次用完即弃**，或**注入仍留在客户端完成**（relay 仅代理字节）——二选一的具体取向留给 ADR-003/009，但上述"零落盘 + 用完即弃/客户端注入"是**任何方案都必须满足的硬约束**。
- 在 relay 方案定案前，**fetch-via-relay 不落地**。

### 2.x 选型对比

| 取向 | 取 | 舍 |
|---|---|---|
| **核心托管 WebView 收割 session（主路径）** | 自动兼容验证码/2FA/SSO/JS 挑战；口令进学校页非核心；最少 per-school 维护 | 引入 WebView 攻击面（§3.2）；session 收割逻辑是安全敏感代码 |
| 核心 headless 模拟登录 | 无 WebView、可后台静默 | 每校登录流程要逆向并跟随其反爬变动；验证码/2FA 几乎不可解；维护爆炸 |
| 让 adapter 参与登录 | 最灵活 | **违背红线 #1/#5**，否决 |

---

## 3. 已知约束与风险（Consequences，草案）

1. **最高敏感路径（红线 #1）。** 实现与测试**不得 AI 独自闭环**；需安全检查清单 + 人工审阅（git.md §3、testing.md）。
2. **WebView 是新攻击面。** 必须：核心独占控制、与 adapter 运行时**进程/上下文隔离**、**禁止导航出声明的登录域**、禁注入任意脚本、收割后即销毁会话上下文。cookie 收割逻辑须按承重路径审。
3. **收割 session 而非口令降低暴露，但 session 本身仍是凭证。** at-rest 加密 + OS keystore 是底线；内存中明文窗口最小化（注入瞬间解密、用完即弃）。
4. **声明式刷新配方若入 manifest = 契约改动**（红线 #6），独立 ADR、向后兼容；配方表达力须谨慎（避免变成图灵完备的"伪 adapter"反而成新代码注入面）。
5. **campus-relay 凭证传输是开放风险**（§2.6），未解前 fetch-via-relay 不落地。
6. **iOS 联动 ADR-010。** WebView 登录 + Keychain + session 收割需在 5.1.1 隐私申报披露；首版仅 parser，本文随 fetch 模式一并做 2.5.2 自检。
7. **桌面 Linux secret storage 可用性是已知弱点**（无统一 keyring 时的回退策略需定，且回退不得降级为明文落盘）。
8. **首次"代取"也需要凭证。** 即便 parser 模式，"核心代取私密页"也依赖本文的凭证——因此本文不仅服务 fetch 模式，也是 parser 模式取私密数据的前提。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

> 安全敏感项标 🔒（人工主导、AI 仅辅助）：

- 🔒 核心**安全存储抽象**（iOS Keychain / Android Keystore / 桌面 Secret Service）+ at-rest 加密；统一"按 ref 存/取/删"接口。
- 🔒 **核心托管 WebView 登录 + session 收割**（客户端；导航域闭锁、上下文隔离、收割后销毁）。
- 🔒 **`CredentialEntry` 模型 + credential reference 解析**，与 ADR-009 broker 注入对接（scope ⊆ network.allow 校验）。
- **生命周期**：过期检测（401/302→登录页）、登出抹除、吊销联动（与 ADR-002 kill-switch）。
- 声明式刷新配方（可选，**独立契约 ADR**，向后兼容）。
- campus-relay 凭证落点设计（与 ADR-003/009 协调，本文后续）。
- 测试：存储加解密往返、登出确实抹除、过期/续期路径；WebView 收割的安全敏感测试**人工编写或实质审阅**（testing.md）。
- iOS 合规评估（ADR-010 §3.3 的 2.5.2 自检 + 5.1.1 隐私申报）。
