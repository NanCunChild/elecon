# ADR-012：凭证获取（登录）与可信核心凭证存储

- **状态**：已接受（Accepted） 本文触碰红线 #1（凭证）的**最高风险面**——凭证从哪来、存哪、什么形态。按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，经人工 review（PR #23）+ 安全检查清单审阅后接受。
- **日期**：2026-06-13（历次修订见文末[附录：修订记录](#附录修订记录)）
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§3.3 凭证边界、§2.2 可信核心）、[`adr_001_contract.md`](./adr_001_contract.md)（manifest / 契约）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（谁有资格用凭证 = official）、[`adr_003_transport.md`](./adr_003_transport.md)（campus-relay 落点）、[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（客户端核心）
- **被依赖**：[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（其 §2.3 的 "credential reference" 正是指向本文定义的凭证条目；其注入消费本文的存储）
- **相关 issue**：[#3](https://github.com/NanCunChild/elecon/issues/3)、[#17](https://github.com/NanCunChild/elecon/issues/17)；本文回应 #8/#10 评审指出的"**凭证存储 + 登录获取孤儿缺口**"。
- **适用范围**：凭证如何被**获取**（登录）、如何在**可信核心**存储与做生命周期管理、credential reference 的**数据形态**。**不含**：凭证如何注入出站请求（[`adr_009`](./adr_009_fetch_credential.md)）、谁有资格用（[`adr_002`](./adr_002_trust_model.md)）、传输底座本身（[`adr_003`](./adr_003_transport.md)）。

---

## 1. 背景（Context）

ADR-005/008 的 declarative requestGraph 靠"核心代取 + 脱敏 → adapter 纯解析"。但"**代取**"这一步本身就需要凭证——而当前核心**没有任何凭证获取/存储机制**：客户端未接入任何安全存储，`server/src/campus` 是 stub（"尚未实现"）。

ADR-009 假定"按 reference 注入凭证"，ADR-002 假定"official 才有凭证注入资格"，但**凭证从哪来、存哪、是什么数据形态**——两者都没认领。这是 imperative requestGraph（乃至 declarative 代取）真正的**地基**。#8 与 #10 的评审都把它点成了悬空缺口。

红线约束：
- #1 凭证（值与任何等价物）永不离开可信核心。
- #2 公网哑服务零凭证、无状态。
- #3 私密数据只走 client-direct 或 campus-relay。

**核心难题（本文要解的张力）**：登录流程**高度校校异**——端点、CSRF、验证码、2FA、SSO 跳转、JS 挑战各不相同，天然像"需要一段 per-school 代码"；但红线 #1 + #4/#5 要求**凭证绝不经过 adapter**，且 DEPLOY 无论 catalog / 本地来源都只运行 official。DEV-Sideload 虽可全能力调试，凭证值也仍留在核心。**如何在不让 adapter 碰凭证的前提下完成校异登录？**

---

## 2. 决策（Decision，草案）

> 以下为**待审议**取向，非既定事实。每条都需安全审阅确认。

### 2.1 凭证只存于可信核心，客户端是权威存储（canonical store）

凭证以**设备本地 OS 安全存储**加密落盘：iOS Keychain / Android Keystore / 桌面 Secret Service（libsecret/keyring）。adapter、UI 层、公网服务端**永不**持有（红线 #1/#2）。存储抽象统一封装，向上只暴露"按 ref 取/存/删"，不暴露明文。

> **威胁模型、保护对象、平台后端矩阵、密钥托管（key custody）、at-rest 加密、无 keyring 的桌面回退、以及"生产禁止明文默认后端"的 fail-closed 规则，见 §2.7（2026-07-04 补全）。** §2.7 之前 §2.1 只给了方向（"OS 安全存储"），未定各平台落点与 key custody（文件历史标注的开放问题）——§2.7 认领之。

### 2.2 登录主路径：「核心托管 WebView」——把校异与人机交互外包给学校登录页

不自己模拟每所学校的登录请求，而是：

1. 核心打开一个**核心控制的 WebView**，加载学校**真实登录页**（URL 由 official manifest 声明，受 ADR-002 签名约束）。
2. 用户在**学校自己的页面**输入账号密码——凭证进的是学校页面，**不经过 adapter，甚至不必进核心的字段存储**。
3. 登录成功后，核心从 WebView 的 cookie jar / 存储中**收割 session 凭证**（cookie / token），存入 §2.1 安全存储。**核心收割的是登录结果（session），不强制持有原始口令**——进一步缩小红线 #1 暴露面。

   > **同一收割动作也服务 imperative 握手（2026-06-14，与 [`adr_009`](./adr_009_fetch_credential.md) §2.4 协调）**：imperative adapter 经 `ctx.fetch` 完成多步反爬/握手后，origin 下发的**耐久 session cookie** 同样在执行结束时由核心收割进本存储——触发点从"WebView 登录页"扩展到"imperative 握手结束"，但收割逻辑、安全边界、`CredentialEntry` 形态一致。**收割判据 = manifest `credentials.<name>` 显式声明的 ref（判据 b）**，未声明者一律丢弃（不持久化），封死"诱导 origin 下发任意 cookie 入库"的面。adapter 全程不可见值。
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

### 2.7 安全存储威胁模型 + 平台矩阵 + 密钥托管（2026-07-04 补全，已接受）

> **本节补全 §2.1 遗留的开放问题**（`secure_store.dart` 文件头「key custody 仍是开放问题」）。触红线 #1 最高风险面，按 AGENTS.md §1 **AI 不得独自闭环**：本节由 AI 起草（跟踪 #79 P0-2），经人工审阅后接受。护栏部分（生产禁默认明文后端）已先行落地（PR #82），设计部分（平台实现）按本节拆 PR 实现。

**决策 A：先收窄防御对象——只承诺防 at-rest / offline / 低权限本地窃取，不承诺防 rootkit。** 安全存储保护的是「凭证落盘后的离线窃取面」：设备备份泄露、应用沙盒文件被拷走、磁盘镜像、非 root 同机进程等。它**不**承诺抵抗 rootkit / 内核级 / 已控制本进程内存的攻击者：若攻击者能读进程内存、hook Keychain/Keystore API、截获解密后的注入瞬间，客户端侧加密已不能提供实质防御；此时只能依赖最小明文窗口、登出/吊销、重新认证和设备安全姿态。本文不以这类攻击作为 v1 at-rest 加密的主要防御对象。

**决策 B：核心保密对象是可重放凭证材料，即 `CredentialEntry.value`。** `value` 内含 cookie/header token/session secret，泄露即可重放认证状态，必须进入平台安全存储。`ref` / `schoolId` / `type` / `scope` / `acquiredAt` / `expiresAt` / `status` 是注入决策和生命周期元数据，不描述为同等级秘密；实现可随平台存储一起保存，或在不泄露 `value` 的前提下明文保存必要索引，但不得让元数据成为新的注入权威（§2.4 已定权威在 manifest）。这样避免把「整库全字段加密」误当成目标，也避免后端实现不知道加密范围。

**决策 C：优先"直存 OS secure storage"，app 不自持长期密钥；不承诺跨平台 TEE 语义。** at-rest 加密需要密钥，密钥又存哪——若 app 内嵌静态密钥，那只是混淆、非加密（密钥随二进制分发即等于无密钥）。取向：**凡 OS 提供"存任意 secret"的安全存储，直接把 `CredentialEntry.value` 存进去**，由 OS 负责加密 + 密钥托管，app 侧**不持有任何长期密钥**。Secure Enclave / StrongBox / TPM / Secret Service 的硬件背书、备份行为、解锁条件差异很大；v1 只承诺使用平台官方 secure storage，硬件-backed 是优先/加分项，不是跨平台不变量。

| 平台 | 后端 | 密钥托管 |
|---|---|---|
| iOS / macOS | **Keychain**（`kSecClassGenericPassword`，`WhenUnlockedThisDeviceOnly`） | OS Keychain；硬件背书不作为跨平台承诺 |
| Android | **EncryptedSharedPreferences** / DataStore + Android Keystore 托管 KEK | Android Keystore；StrongBox 可用则优先，不作为必需 |
| Windows | **DPAPI**（`CryptProtectData`，用户范围）/ Credential Manager | OS 用户登录密钥 |
| Linux（桌面，有 keyring） | **Secret Service**（libsecret → gnome-keyring / KWallet） | keyring daemon（随登录会话解锁） |
| Linux（无 Secret Service）/ headless | **无合法后端 → fail-closed**（见决策 E） | —— |

**决策 D：app 侧 AEAD 仅作为平台要求时的例外路径，不是默认目标。** 少数后端只托管密钥、不托管任意 secret blob——此时 app 可用 OS/keystore 托管的 KEK 对 `CredentialEntry.value` 做 **AEAD（AES-256-GCM）** 加密后落盘，**明文密钥永不出 keystore、永不入仓、永不内嵌**。绝不自造加密原语，优先使用平台/审计过的库。默认路径仍是决策 C 的"直存 OS secure storage"；D 是被平台 API 形态迫使的例外，不是跨平台自建加密层。

**决策 E：无 keyring 的桌面/headless 一律 fail-closed，绝不明文落盘（认领 §3.7）。**（⚠ **2026-07-09 §2.8 修订**：本决策的「一律内存-only」被放宽为知情同意的分级回退——用户可选 S 软件档持久化或 M 内存档；「取消」即回到本决策的旧 fail-closed 行为。见 §2.8。） §3.7 早已划红线「回退不得降级为明文落盘」，本节给出具体回退：**无可用 Secret Service 时，凭证转为内存-only**（不落盘、不跨进程重启存活；下次启动需重新 §2.2 登录），并给持久 UI 警示。这与 §2.1 权威存储的耐久性目标冲突，但**fail-closed 优先于可用性**（与 [`adr_002`](./adr_002_trust_model.md) fail-toward-less-trust、#79 P0-2 release 无真实后端即 fail-closed 同构）。**passphrase 派生 KEK（Argon2id）** 作为可选的"无 keyring 也能持久化"路径**留待后续独立决策**——它引入用户口令 UX 与 KDF 参数面，不进 v1，不在本节承诺。

**决策 F：生产禁止静默使用明文内存后端（护栏，PR #82 已落地）。** `InMemorySecureStore` 是**明文内存原型后端**，仅供 dev/test。生产（Dart `kReleaseMode` / TS `NODE_ENV=production`）下省略 store 的构造**fail-closed 抛错**，不静默回退明文内存——安全性由机制强制，非靠"生产代码记得注入真实 store"的调用约定。真实后端（决策 C/D）落地前，生产凭证存储整体 fail-closed（与「无真实 secure store 就不该假装能存凭证」一致）。**本决策已实现**（`CredentialStore.defaultSecureStore` / `#defaultStore`，两端镜像），是 §2.7 唯一已落地项；A–E 按平台拆 PR 实现。

**不变量（贯穿 A–F）**：① app 侧**永不**持有内嵌/静态长期密钥；② `CredentialEntry.value` 明文**永不落盘**（无后端即内存-only 或 fail-closed）；③ 不把 rootkit/进程内存读取列为 at-rest 加密可解决的目标；④ 不承诺统一 TEE/硬件背书语义；⑤ 内存中明文窗口最小化（注入瞬间解密、用完即弃，§2.4）；⑥ 后端实现是宿主侧安全敏感代码，随实现 PR 人工 + 安全清单审（不得 AI 独自闭环）。

> **⚠ 2026-07-09 §2.8 修订**：不变量 ② 中「无后端即内存-only 或 fail-closed」被放宽为「知情同意的分级回退」，见 §2.8（②′）。

### 2.8 无硬件加密时的分级回退：知情同意的软件加密档（2026-07-09 修订，已接受）

> **本节修订 §2.7 决策 E 与不变量 ②。** 原「无 keyring / 无硬件 → 一律内存-only、fail-closed、绝不落盘」放宽为「**信封加密分级回退 + 用户知情同意**」。**修订理由**：无硬件加密的设备（桌面 Linux 无 keyring、极少数无 Keystore 的旧 Android）上强制内存-only = 每次启动都要重新 §2.2 登录，可用性代价过高；改为把「是否以较弱的软件加密持久化」的选择权交给用户，以**强警示 + 强制等待 + 显式同意**作为补偿控制。**触红线 #1，本节由 AI 起草、经人工审阅后接受（维护者 2026-07-09）；三档加密实现及测试仍须人工主导 + 安全清单 + ≥1 人工审，不得 AI 独自闭环。**

> **作用域声明（ADR-000 §2.3.1）**：本节的「信封」是密码学行业通名 **envelope encryption**（DEK/KEK 两层密钥），**与 [`adr_001`](./adr_001_contract.md) §3.3 的数据信封、[`adr_018`](./adr_018_adapter_distribution.md) §2.9 的 bundle 信封没有任何关系**——它是密钥管理模型，不是数据格式。本文其余处出现的「信封」均指此义。

**信封加密模型（envelope encryption），三档保护。** 统一 DEK/KEK 信封（推广 §2.7 决策 D）：随机 **DEK（AES-256）** 对 `CredentialEntry.value` 做 **AEAD（AES-256-GCM）** 加密（决策 B 保密对象不变；绝不自造原语，用平台/审计过的库）。DEK 的保护分三档：

| 档 | 触发条件 | DEK 保护 | 持久化 | 标注（登记）|
|---|---|---|---|---|
| **H 硬件档** | 设备有硬件加密（TEE / SE / StrongBox / Keystore，非对称公钥或对称 KEK）| KEK **包裹 DEK**（wrap）；KEK 私钥/对称密钥**永不出硬件**，unwrap 须硬件参与 | app 私有目录（密文 value + wrapped DEK + 元数据）| `protection: hardware`, `wrapped: true` = **「已加密」** |
| **S 软件档** | 无硬件加密，用户经警示后点「继续」| DEK **明文**与密文并存于 app 私有目录（**不加密**）| app 私有目录 | `protection: software`, `wrapped: false` |
| **M 内存档** | 用户点「取消」，或未同意软件档 | DEK 仅在内存，进程退出即失 | **不落盘**（= §2.7 决策 E 旧行为）| `protection: memory` |

**「继续 / 取消」闸门（客户端 UI 行为约束）：**

- 检测到无硬件加密方案时，**必须**弹出警告框，明确告知：软件档下密钥未受硬件保护，能读取 app 私有目录者（root、备份导出、取证、磁盘镜像）可解出凭证——**其保密性≈明文**，仅比裸明文多一层格式化封装。
- 警告框**强制等待 5 秒**后方可点「继续」（防无意识连点）。
- 「继续」→ 启用 **S 软件档**持久化；「取消」→ 落 **M 内存档**（本进程内有效，退出即需重新登录）。
- 选择软件档后，设置页 / 状态处**须持续显示**「软件加密（无硬件保护）」标识，不隐藏风险。

**Android 落点。** H / S 两档的密文 value、DEK（wrapped 或明文）、元数据均存 **app 私有目录**（`getFilesDir()`，per-app sandbox）。**必须** `android:allowBackup="false"` + 从 auto-backup / 云备份排除——堵住「软件档明文 DEK 随备份外泄」这一最现实向量（iOS 对应 `isExcludedFromBackup`）。

**「做好标注」= 敏感度分级驱动保护策略。** `CredentialEntry` 增**非密**元数据 `sensitivity`（`master` / `standard`）与 `protection`（`hardware|software|memory` + `wrapped`）。标注**不作注入权威**（§2.4 权威仍在 manifest），只驱动**保护策略**与 UI 呈现。

**母凭证（ADR-017 `sso-master`）——决策（维护者 2026-07-09 拍板）：一并纳入 S 软件档，同一知情同意。** 母凭证可静默换任意下游 session，是最高价值目标；软件档下它同样以明文 DEK 持久化，换取「重启不用重登」的一致体验。**代价明确**：这是全档最高价值凭证暴露在≈明文存储下，风险显著高于只暴露下游 session。**补偿控制**：§2.8 的警告框**必须显式点名**——软件档会把「可访问你全部校园服务的主凭证（SSO 母凭证）」以未受硬件保护的形式存于本机；用户 5 秒等待后知情同意方可继续。`sensitivity: master` 仍保留为**非密元数据**用于 UI 高价值标识（据此在设置页突出显示，并**提供可选「仅母凭证不持久化」开关**作安全阀，默认关、落地阶段定），但**不改变默认持久化策略**。（备选「母凭证强制内存档」已评估否决：体验割裂，且与「知情同意后统一持久化」取向不一致。）

**修订后不变量（覆盖 §2.7 ②，其余 ①③④⑤⑥ 不变）：**

- **②′** 裸明文 `value` **永不落盘**——三档下 value 均经 AES-256-GCM 加密后才落盘（S 档差别仅在 **DEK 明文落盘**，且须用户知情同意）；DEK 明文落盘**仅限 S 软件档**。
- **⑦（不变）** app 侧**永不内嵌/静态长期密钥**：S 档 DEK 是每安装随机生成（非内嵌），H 档 KEK 在硬件——决策 C 该不变量保持。

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
6. **iOS 联动 ADR-010。** WebView 登录 + Keychain + session 收割需在 5.1.1 隐私申报披露；首版仅 declarative，本文随 imperative requestGraph 一并做 2.5.2 自检。
7. **桌面 Linux secret storage 可用性是已知弱点**（无统一 keyring 时的回退策略需定，且回退不得降级为明文落盘）。**回退策略已由 §2.7 决策 E 定案（2026-07-04，已接受）**：无 Secret Service → 凭证内存-only + fail-closed，绝不明文落盘；passphrase 派生 KEK 留待后续独立决策。**（§2.8 修订，2026-07-09 已接受：放宽为知情同意的分级回退，见下条 9。）**
8. **首次"代取"也需要凭证。** 即便 declarative requestGraph，"核心代取私密页"也依赖本文的凭证——因此本文不仅服务 imperative，也是 declarative 取私密数据的前提。
9. **S 软件档是有意识的安全弱化，非疏漏（§2.8）。** 软件档下明文 DEK 与密文并存，对能读 app 私有目录者（root / 备份导出 / 取证）保密性≈明文。补偿控制 = 5 秒强制等待 + 知情同意（警告框**显式点名** SSO 母凭证一并以≈明文持久化，§2.8 决策）+ 备份排除 + 持续 UI 警示。**文档 / UI 绝不得把软件档描述为"受保护加密"而误导用户。** 更强的软件档升级路径是 **passphrase 派生 KEK（Argon2id）** 包裹 DEK（DEK 不明文落盘），本修订未采用（引入口令 UX + KDF 参数面，§2.7 决策 E 已推迟），列为可选未来增强。
10. **备份排除是 S 软件档最关键实现细节。** `allowBackup=false` / auto-backup 排除（Android）、`isExcludedFromBackup`（iOS）遗漏则软件档明文 DEK 随云备份外泄，风险陡升——须列入 §2.8 实现的安全清单必检项。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR ，落地后删除）

> 安全敏感项标：

- 核心**安全存储抽象**（iOS Keychain / Android Keystore / 桌面 Secret Service）+ at-rest 加密；统一"按 ref 存/取/删"接口。**威胁模型、保护对象、平台后端矩阵 + key custody + 无 keyring 回退见 §2.7（已接受）**：
  - [x] **护栏（§2.7 决策 F，PR #82 已落地）**：生产禁默认明文内存后端，fail-closed。
  - [ ] iOS/macOS Keychain 后端（§2.7 决策 C）。🔒
  - [ ] Android Keystore 支撑的 EncryptedSharedPreferences 后端（§2.7 决策 C/D）。🔒
  - [ ] 桌面 Secret Service / DPAPI 后端 + 无 keyring 的 fail-closed 回退（§2.7 决策 C/E）。🔒
  - [x] **§2.8 分级回退**（已落地，提交 `9f1825e`/`2012e21`）：信封加密 DEK/KEK；H 硬件档 wrap/unwrap（iOS SE / Android Keystore）；S 软件档明文 DEK 落盘 + `allowBackup=false`/备份排除；M 内存档；`sensitivity`/`protection` 标注。**残留**：可选「仅母凭证不持久化」开关（默认关）尚未接入。🔒
  - [ ] **§2.8 UI**：无硬件加密警告框 + 5 秒强制等待 + 继续/取消 + 软件档持续风险标识。
  - [ ] 登出抹除 / 过期 / 吊销联动在各真实后端（含三档）的一致行为测试。
- **核心托管 WebView 登录 + session 收割**（客户端；导航域闭锁、上下文隔离、收割后销毁）。**登录声明面（去哪登 / 导航闭锁 navigationAllow / 成功检测）见 [ADR-015](./adr_015_manifest_login.md) 的 manifest `login` 块（草案）。**
- **`CredentialEntry` 模型 + credential reference 解析**，与 ADR-009 broker 注入对接（scope ⊆ network.allow 校验）。
- **生命周期**：过期检测（401/302→登录页）、登出抹除、吊销联动（与 ADR-002 kill-switch）。
- 声明式刷新配方（可选，**独立契约 ADR**，向后兼容）。
- campus-relay 凭证落点设计（与 ADR-003/009 协调，本文后续）。
- 测试：存储加解密往返、登出确实抹除、过期/续期路径；WebView 收割的安全敏感测试**人工编写或实质审阅**（testing.md）。
- iOS 合规评估（ADR-010 §3.3 的 2.5.2 自检 + 5.1.1 隐私申报）。

---

## 附录：修订记录

> 从头部 **日期** 行移出，便于阅读；内容不变（红线 #1 决策，历次均经人工 + 安全清单审）。

- **2026-06-14**：① §2.2 增 imperative 握手的耐久 session 收割——与 WebView 登录同一动作、判据 = manifest 声明的 credential ref（判据 b），与 [`adr_009`](./adr_009_fetch_credential.md) §2.4 / [`adr_013`](./adr_013_manifest_credentials.md) 协调；② §2.4 闭合 scope/type 双源——store 保留为防御性副本+一致性基准，注入权威唯一在已验签 manifest，不一致以 manifest 为准并告警；③ §2.6 钉定首版仅 client-direct，relay 凭证落点推迟、本 ADR 不依赖 relay，relay 须满足"零落盘+用完即弃/客户端注入"硬约束。
- **2026-07-04（已接受，#79 P0-2）**：新增 §2.7 安全存储威胁模型 + 保护对象边界 + 平台后端矩阵 + 密钥托管 + 无 keyring 桌面 fail-closed 回退 + 生产禁默认明文后端护栏——认领 §2.1/§3.7 遗留的 key custody 开放问题；护栏部分已实现 PR #82，平台后端按本补全拆 PR。
- **2026-07-09（已接受）**：新增 §2.8——无硬件加密时由「一律内存-only / fail-closed」放宽为「知情同意的分级回退」：H 硬件档（KEK 包裹 DEK）/ S 软件档（DEK 明文落盘，5 秒警示后用户同意）/ M 内存档（取消即旧 fail-closed 行为）；修订 §2.7 决策 E 与不变量 ②；触红线 #1，须人工 + 安全清单审。
