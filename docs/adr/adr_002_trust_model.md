# ADR-002：插件信任模型（签名 / 吊销 / dev 侧载闸门）与能力分档（official / sideload）

- **状态**：已接受（Accepted） 2026-06-13 经人工安全检查清单全项确认后接受。实现仍须按 AGENTS.md §1 人工主导（红线 #1/#4/#5 承重路径）。
- **日期**：2026-06-11（**修订 2026-06-12**：补 §2.3 签名时档位来源与签名权、公钥轮换搭发版、§2.4 吊销 bootstrap、§2.1 community 取舍——回应人工复核 1–4）（**修订 2026-06-13**：**砍掉 community 档**（社区走 sideload、官方均 official）、§2.3 签名密钥改 **OIDC→AWS KMS 委托签名** + **多公钥预埋分批启用**、§2.5 release 编译期剔除侧载、§2.6 `ctx.fetch` 改"存在但档位校验"——落 #10 评审决策）（**修订 2026-06-13b**：§2.3 **钉死规范化规格**（字典序/LF/UTF-8 NFC/无 trailing newline 篡改）、KMS 硬 deadline = 首次 release 前、dormant 公钥晋升**纯发版**不做热推启用声明）（**修订 2026-06-14**（人工 owner 决策）：① §2.5 **dev/debug build 允许无签名 adapter 跑 fetch**——release 仍 official 独占 fetch，dev 用强警告 + 全占用确认兜底，侧载-fetch 路径编译期从 release 剔除（同步红线 #5 的 dev 例外）；② **community 档从 manifest schema 彻底移除**（不再保留枚举位），契约同步改 `contract/manifest.schema.json` + ADR-001 §5）（**修订 2026-07-15**（**经人工 owner 评审批准**，随 [`adr_018`](./adr_018_adapter_distribution.md) 一并接受）：**§2.3 签名密钥托管由「OIDC→AWS KMS 委托签名」改为「离线硬件密钥（YubiKey）本地签名」**——理由：AWS 连通性/成本对本项目体量不划算，且离线硬件签把私钥彻底移出任何服务器/CI，比 KMS 更贴合 §2.3「私钥永不落盒子 + 签 official=显式人工批准」的意图。签名机制细节与分发/审计管线随 [`adr_018`](./adr_018_adapter_distribution.md) 定；本 ADR 仅同步 §2.3/§3/§4 的对应描述。**验签侧（Ed25519 + 预埋 pin 公钥、fail-closed）与多公钥预埋/晋升机制完全不变。**）（**修订 2026-07-16**（**经人工 owner 评审批准**，真机接线后回填）：① **§2.3 硬件签名由「尚未接线」改为「已接线并经真机核验」**——`YubiKeyPkcs11Signer`（PIV/PKCS#11 `CKM_EDDSA`）出签自检通过，首把 official 密钥 `elecon-official-ncc-1` 已片上生成（YubiKey 5C NFC / 固件 5.7.4 / 槽位 9c / PIN+触碰 ALWAYS），§2.3 硬 deadline 达成；② **§2.3 新增「不使用 X.509 证书」决策**——实测 libykcs11 走 PIV metadata 枚举、无证书亦可出签，故信任锚只有裸 32B Ed25519 公钥，🔒 加载器不碰 X.509（红线 #4 加载器最小化）；③ **§2.3 新增触碰策略静默失效警告**——`touch-policy` 生成时固化、漏设不报错只静默降级，ceremony 须复核；④ **§3 风险 2 补残余风险 (d) 令牌兼作日常随身 GPG、(e)「所见非所签」**；⑤ **§4 声明新依赖 `pkcs11js`（MIT，`optionalDependencies`，仅离线签名机）**（红线 #9）。**验签侧、pin 公钥体系、多公钥预埋/晋升机制仍完全不变。**）
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§2.2 可信核心、§3.3 凭证边界、§3.4 传输底座）、[`adr_001_contract.md`](./adr_001_contract.md)（§5.2 信任档字段；community 策略原留给本文细化——本文**决定砍掉**，见 §2.1）
- **被依赖**：[`adr_009`](./adr_009_fetch_credential.md)（imperative requestGraph 凭证注入，trust tier 由本文裁定）、[`adr_003`](./adr_003_transport.md)（传输底座抽象，仅官方签名可加载）、[`adr_018`](./adr_018_adapter_distribution.md)（adapter 分离/审计/打包/分发 + 解释器版本同步——落地本文 §2.3 的签名管线与 §2.4 的清单分发）；并为 [`adr_010`](./adr_010_ios_appstore.md) 的 App Store 合规论点 (b)「非代码市场」提供支撑（无侧载入口 + 仅签名分发）。
- **适用范围**：adapter（QuickJS 脚本）与传输底座（原生模块）的**信任建立、能力分档、分发与吊销**。**不含** 凭证注入的具体脱敏机制（另文）、UI 信任（不在此）。

---

## 1. 背景（Context）

ADR-000 §2.2 把"签名校验、吊销、dev 侧载闸门"定为可信核心的职责，§3.3/§3.4 给了三档能力分级与"传输底座仅官方签名"的方向，但没定**机制**。ADR-001 固定了 manifest `trustTier` 字段（official / community / sideload）并明确把 **community 策略与签名机制留给本文**。`tools/src/signer` 目前是 stub。

需要回答的核心问题：**凭什么相信一个 adapter？相信到什么程度（能拿凭证吗？能进 release 吗？）？怎么撤回信任？**

红线约束（承重墙，不可违背）：
- #1 凭证永不离核心 → 只有最高信任档才有资格触发凭证注入。
- #4 传输底座仅官方签名加载且无侧载；DEPLOY adapter 无论字节来源都只运行 official；dev 传输仅 debug build。
- #5 DEPLOY 不运行未签名 / 非 official adapter；DEV-Sideload 是全能力调试例外，凭证值仍不离核心，见 §2.5。DEPLOY 本地 official 导入与 C3 退役由 ADR-033 提议，接受前不得实现。

---

## 2. 决策（Decision，草案）

> 以下为**待审议**取向，非既定事实。每条都需安全审阅确认。

### 2.1 两个正交维度：签名管「分发」，信任档管「能力」

把两件常被混为一谈的事拆开：

- **是否通过 official 验签** → 决定**能否在 DEPLOY 运行**。字节可来自 catalog，或在 ADR-033 接受后来自用户显式本地导入；来源不改变 trust tier。未签名 = 仅 DEV-Sideload。
- **信任档** → 决定**能做什么**（能力上限）。

| 档 | 建立方式 | 分发 | 能力上限（DEPLOY） | 能力上限（DEV profile） | 执行落点 |
|---|---|---|---|---|---|
| **official** | 一方编写或深度审查 + 项目签名 | DEPLOY（catalog；ADR-033 提议增加本地文件来源） | **imperative / declarative requestGraph**、当前正式宿主能力 | 同 DEPLOY | client-direct / campus-relay |
| **sideload / devSideload** | 开发者本地加载，**无签名** | **仅 DEV-Sideload，不可分发** | —（DEPLOY 不运行此档） | **全能力调试**：imperative / declarative、当前 DEV 宿主已编入能力；须强警告 + 全占用确认 | DEV 专用 |

**DEPLOY 下凭证注入（imperative requestGraph；旧称 fetch 模式，见 ADR-022）是 official 独占**——把最高风险面锁死在项目授权代码上。**DEV-Sideload 例外**：无签名 adapter 可调试 imperative 及当前 DEV 宿主能力、可触发开发者测试凭证注入；以多重警告兜底，未签名 grant 与 dev 凭证放行路径编译期不进入 DEPLOY。ADR-033 的 DEPLOY 本地导入即使落地，也只铸造 official grant，不改变此不变量。

**community 档已砍（2026-06-13 决定）**：原拟的 community 与 sideload 能力上限相同（都 declarative-only），背书签名只买到「能经官方渠道分发」，代价却是**维护者须逐个审查并背书**——正是 ADR-000 要消除的人工瓶颈。权衡后**取消 community 档**：信任模型只剩 **official** 与 **sideload** 两档。社区贡献的 adapter 一律走 **sideload**（贡献者自行 debug 加载，或经审查被收编为 official）；**官方维护 / 深度审查的 adapter 一律 official**。这把维护者从"为可分发性背书"的责任里解放出来，与「最小人力」主线对齐。代价：**没有"已签名可分发但仍由社区维护"的中间态**——可分发即官方背书。核心**无 community 验证路径**，任何自报 community 的包按 sideload 处理（§2.2）。**契约清理（2026-06-14 人工 owner 决策）**：`community` 枚举值**从 `contract/manifest.schema.json` 与 ADR-001 §5 彻底移除**（不再保留枚举位）。这属契约改动（红线 #6），向后兼容性说明：`community` 此前**无任何生效验证路径**（运行时一律按 sideload 处理），移除后自报 `community` 的 manifest 在 `tools/` 静态校验阶段即被拒——行为从"运行时降级"前移为"加载前拒绝"，不放松任何安全约束。

### 2.2 信任档由「签名背书」裁定，不信任 manifest 自报字段

manifest 里的 `trustTier` 只是**声明（claim）**，不是依据。**权威信任档来自核心对签名/背书的验证**：

- 一个侧载包把 `trustTier: "official"` 写进 manifest **不能**提权——核心验不到对应签名；DEPLOY 直接拒绝，DEV 才可按 sideload 本地加载。
- 签名载荷**覆盖** `adapterId` + `adapterVersion` + 内容哈希 + **裁定档位**（两档制下即 official；无签名 = sideload），使档位不可伪造。核心以"验签得到的档位"为准；与 manifest 自报不符则拒绝加载（fail-closed）。

### 2.3 签名机制

- **签什么**：adapter bundle 的规范化内容哈希（manifest + entry 源码 + 资产）+ **裁定档位**（§2.2），detached 签名。传输底座二进制同理。
- **方案**：**Ed25519**（RFC 8032）签名 over bundle 内容摘要。注意 **Ed25519 内建哈希固定为 SHA-512、不可参数化**——所以"Ed25519 over SHA-256"是范畴错误；这里的 **SHA-256 仅指 bundle 内容摘要**（签什么），与 Ed25519 内部的 SHA-512（怎么签）是两处独立的哈希。
- **规范化规格（canonicalization，已定）**：bundle 内容摘要前须按以下规则规范化，保证同一 bundle 在任何平台算出相同哈希：
  1. **文件排列顺序**：参与哈希的文件按**相对路径的 UTF-8 code point 字典序**排列（`manifest.json` < `src/index.js` < …）。
  2. **换行符**：一律 **LF**（`\n`）；CR/CRLF 在哈希前替换为 LF。
  3. **编码**：一律 **UTF-8 NFC**（Unicode Normalization Form C）。
  4. **无 trailing newline**：文件末尾不追加也不剥除 trailing newline——以磁盘字节为准（规范化只管换行符种类和编码，不改内容长度）。
  5. **二进制资产（图片等）**：不做文本规范化，直接按字节参与哈希。
  6. **哈希拼接**：`SHA-256(file1_bytes) || SHA-256(file2_bytes) || ...`（按上述顺序拼接各文件哈希后，对拼接结果再做一次 SHA-256 得到 **bundle digest**），Ed25519 签名此 digest + 裁定档位的 payload。
- **签名时的档位来源 = 真正的信任根（不可含糊）。** §2.2 说「档位进签名载荷」，那么*签名那一刻*档位从哪来、谁有权签 official，才是整套机制的信任根，必须显式定，不能甩给"CI/release"四个字：
  - **档位不取自待签 bundle 的 manifest 自报**（那是 claim），而由**签名流程的显式决策**注入——即「签 official」是一个**需显式批准的动作**，由项目维护者（release owner）执行。
  - **签名密钥托管：离线硬件密钥（YubiKey）本地签名（2026-07-15 修订，取代原 OIDC→AWS KMS 方案）。** official 私钥**生成并驻留于硬件安全 token（YubiKey，PIV/PKCS#11 槽位，Ed25519）**，**永不导出、绝不入仓、不上任何服务器/CI**。签名是**离线手动一步**：维护者（release owner）在本地机上对 bundle digest（确定性规范化摘要，§2.3 规则）执行 **PIN + 物理触碰**签名，产出 detached `signature.json`。这把「official 签名权」从**一切自动化中彻底移除**——CI/服务器/审查沙箱即便被供应链投毒，也**够不到私钥、无法自动出签**（签名窗口 = 需人在场触碰硬件）。**为何弃 KMS**：AWS 连通性/成本对本项目体量不划算；离线硬件把私钥移出网络与云,较 KMS 的「短 token 委托」更彻底地满足「私钥永不落盒子」。
  - **YubiKey 侧加固（等价 KMS 意图的落地）**：① **人工批准闸门** = PIN + 触碰本身（物理在场 = 显式批准，比 required-reviewer 更硬）；② **审计** = 无云端逐次日志，改用 **git 跟踪的发布台账**（每次签名记 `adapterId/version/digest/date/keyId/签署人`，提交进仓，见 [`adr_018`](./adr_018_adapter_distribution.md)）；③ **kill-switch / 撤销** = 走验签侧的公钥吊销 / kill-switch（§2.4）+ 多公钥晋升（§2.3 下条），不依赖密钥托管方的即时撤销。
  - **⚠ 批准闸门依赖 `touch-policy=ALWAYS`，而该策略会静默失效（2026-07-16 补记）。** 上条 ① 的「触碰 = 物理在场 = 显式批准」**只在密钥生成时设了 `touch-policy=ALWAYS` 才成立**。该策略**在生成时固化、事后不可更改**，且**漏设不报错**——只会静默退化成「PIN 一次登录后即可静默批量出签」（PIN 经 PKCS#11 `C_Login` 后驻留进程内存，ykcs11 会在每次 `C_Sign` 前自动重发 VERIFY）。**注意 `pin-policy=ALWAYS` 挡不住这个，触碰才是真闸门。** 故 ceremony **必须**在生成后立即复核 `ykman piv keys info`（[`signing_ceremony.md`](../reference/signing_ceremony.md) §3.1）——2026-07-16 首次 ceremony 即在此踩坑（生成时漏写 `--touch-policy`），密钥已作废重生成。
  - **现状：硬件签名已接线并经真机核验（2026-07-16；硬 deadline 已达成）。** `YubiKeySignBackend` 经 **`YubiKeyPkcs11Signer`**（`tools/src/signer/pkcs11.ts`，PIV/PKCS#11 `CKM_EDDSA`）接实机，出签自检通过：**片上生成私钥 → PIN + 物理触碰 → 裸 64B Ed25519 → 核心侧验签通过**。首把 official 密钥 **`elecon-official-ncc-1`**（YubiKey 5C NFC，固件 5.7.4，PIV 槽位 **9c**，`pin-policy=ALWAYS` + `touch-policy=ALWAYS`，`Origin: GENERATED` 即片上生成——私钥从不存在于硬件之外）。ceremony 见 [`signing_ceremony.md`](../reference/signing_ceremony.md)。**开发阶段**（未发布的 dev/staging build）仍可用 `LocalDevSignBackend`（本地软 Ed25519）——产物不分发终端用户；**面向用户的 release 一律走硬件签**。
    - **固件下限**：PIV applet 支持 Ed25519 需 **固件 ≥ 5.7.0**（更早的固件 PIV 只有 RSA / ECC P-256/P-384）。这是选型硬约束，换令牌时须先核对。
  - **不使用 X.509 证书：信任锚是裸 32B Ed25519 公钥（2026-07-16 决策，经真机核验）。** PIV/PKCS#11 是**证书导向**的标准，常规做法是往签名槽位放一张自签证书（多数教程称 PKCS#11 模块靠槽位证书才能枚举出密钥）。**elecon 不放证书**——实测 libykcs11 2.7.3 + 固件 5.7.4 走 **PIV metadata** 枚举（固件 5.3+ 特性），槽位内**无任何用户证书时**公钥/私钥对象照常暴露、`CKM_EDDSA` 出签正常，**证书并非必需**。故预埋 / pin 的自始至终只有**裸 32B Ed25519 公钥**（即本节「多公钥预埋」那组），**🔒 加载器不做任何 X.509 解析 / 链构建 / 有效期校验**。**为何这样更好**：① 引入证书就要在 🔒 Dart 加载器里加 ASN.1 解析 + 链校验，与红线 #4「加载器最小化」相悖；② 证书有效期会成为验签的隐性失效源（到期即静默打断），而信任锚本不该有到期语义；③ 少一个可被混淆的身份来源——信任判定只看「pin 公钥 + §2.2 身份核对」两件事。**若日后换用旧固件 / 旧 libykcs11 而回退到「按证书枚举」的老行为**：补一张自签证书即可，**它仍只是 PKCS#11 管道产物、不进信任模型**。
    - 附带（不用于信任判定）：libykcs11 会为槽位密钥合成一张 **attestation 证书**，由 YubiKey 出厂密钥签发，可向第三方**密码学证明**该私钥系片上生成、从未离开硬件。这是个免费的审计物证，但**不是**信任锚——采信它等于把信任根交给 Yubico。
  - 贡献者**不持任何私钥**；社区仓库 CI **无任何签名能力**（签名不在任何自动化里，见 [`adr_018`](./adr_018_adapter_distribution.md) 四信任域）。
- **公钥托管：多公钥预埋 + 分批启用（缓解丢失/泄漏），密钥集合仍随发版变更。** 核心**预埋一组**公钥（pin 进客户端与服务端），而非单把——含 **1 把 active 签名公钥 + 若干 dormant 备用公钥**：
  - **应对私钥丢失**：active 私钥若不可用，**晋升**一把已预埋的备用公钥接替——其公钥已随上次发版下发，无需为"引进新信任根"打紧急发版。
  - **应对私钥泄漏**：对泄漏密钥的**停用 / 吊销走已有签名吊销通道**（§2.4），方向是**收窄信任**（fail toward less trust），可半热生效。
  - **方向不对称（安全要点）**：**收窄信任（停用/吊销）可半热**；**放大信任（晋升一把此前 dormant 的公钥为 active）一律随 App 发版**——不做热推启用声明，不承担边缘安全复杂度。这意味着 active 私钥丢失后的恢复速度受发版节奏限制，用 kill-switch（§2.4）兜急性事件。后续若运营需要更快恢复速度，可另起 ADR 引入签名启用声明机制。
  - **关键不变量**：可被启用的公钥**只能来自已预埋集合**——任何下发信号都无法引入"不在二进制里"的新公钥，§3.2 警告的"更新通道变新信任根入口"因此被**封死在预埋集合内**。增删**整个预埋集合**仍**一律随 App 发版**（与 [`adr_010`](./adr_010_ios_appstore.md)「信任根变更只能随发版」同构，钉在应用商店审核之后）。
- **校验**：核心在加载 official adapter 与传输底座**之前**验签，针对当前 **active** 的 pin 公钥；验不过 → 拒绝（fail-closed）。`tools/src/signer`（经离线 YubiKey 后端）产出签名，核心消费。**验签逻辑与 pin 公钥体系不因签名后端更换而变**——KMS→YubiKey 只改「私钥怎么出签」，不改「核心怎么验签」。

### 2.4 吊销（Revocation）

- **吊销清单**：签名的 revocation list（按 `adapterId` + 版本范围 / 具体 bundle 哈希），经**公网哑服务**分发（公开数据、零凭证，契合红线 #2）。
- **核心行为**：拉取 + 验签吊销清单，拒绝加载被吊销的 bundle；支持**最低版本下限**强制升级有漏洞的 adapter；支持密钥泄露时的总开关（kill-switch）。
- **时效与离线**：吊销清单自带新鲜度/TTL；拉取失败时回退到**上一份已验签的清单**（绝不把"拉不到"当成"全部放行"）。
- **首次启动 / 全新安装的 bootstrap（消解 fail-closed 的两难）。** "回退到上一份已验签清单"在全新安装、**尚无 last-good** 时无依据，会陷入「fail-open 不安全 / fail-closed 离线即不可用」两难。对策：**App bundle 内预置一份初始的已签名吊销清单**（随发版更新），作为 last-good 的初值——新装即有一份可信基线，离线也能 fail-closed 而不瘫。这与 [`adr_010`](./adr_010_ios_appstore.md) §2.2「bundle 预置基线 adapter」同源：让 App 在零网络下即自包含可用。预置清单只是**下限**，联网后按 TTL 拉取更新。

### 2.5 本地导入与 DEV-Sideload 闸门（红线 #4；ADR-033 Proposed 修订）

- **渠道不等于信任档**：DEPLOY 本地文件若通过 official 验签与治理门，仍按 official 运行；`devSideload` 只在 DEV profile 可铸造。
- **当前生效基线**：ADR-033 接受前，ADR-024 的 DEPLOY 零本地导入实现与 gate 保持不变。
- **提议后的 DEPLOY**：设置内保留低频本地导入，只接受 official 签名；每次新增/更新必须在线刷新并验证 catalog/revocation，网络失败、陈旧、回滚、吊销或身份不符均拒绝。入口低可达性不替代安全门禁。
- dev 传输底座同样**仅 debug build**存在（红线 #4）。
- **DEV-Sideload 全部允许**：无签名 adapter 可用 declarative / imperative，并调试登录、收割、ssoMint、dataflow、action 等当前 DEV 宿主已编入能力；可触发开发者测试凭证注入，但凭证值仍不离核心。DEV 可以是优化的 `--release` build，必须使用独立 applicationId、启动警告且不可分发。**风险以多重警告兜底，不以 declarative 阉割兜底**：
  - **DEV 启动即提示**：进入 DEV profile 时持久提示「当前为开发版；未审查 adapter 可驱动核心使用开发者测试凭证、读取脱敏后的私密响应并在声明白名单内发请求」。不得表述成 adapter 能看到凭证值；红线 #1 在 DEV 仍成立。
  - **侧载 imperative adapter 时全占用确认**：加载含 `requestGraph: imperative` 的无签名 adapter 前，弹**全占用模态框**逐条列明风险（该 adapter 未经签名/审查、将获得凭证注入能力、可读取私密响应），用户须显式确认方可继续。
  - 上述警告 UI 与"允许注入"分支均挂在编译期 `kSideloadEnabled` 下，**DEPLOY 不存在**。
- **DEPLOY 维持信任约束不变**：任何未签名 / 非 official adapter 无运行路径。ADR-033 只提议增加 official bundle 的本地字节来源，不增加生产低信任档。

### 2.6 纵深防御：静态（tools）+ 运行时（core）

| 闸门 | 位置 | 职责 |
|---|---|---|
| 静态 | `tools/` 校验器（CI） | 校验 requestGraph 结构、白名单、凭证引用、capability registry 与能力专属规则。当前 C3 仍拒 `sideload + imperative`；ADR-033 提议退役 C3，使 DEV 素材可完整预检，接受前不得先改实现。 |
| 运行时 | 可信核心 | DEPLOY 无论 catalog / 本地来源都只接受 official 验签 + 身份绑定 + 吊销 + stdlib 门全过的 bundle；本地新增/更新额外要求在线新鲜治理材料。DEV-Sideload 可铸造未签名开发 context，但该路径不进入 DEPLOY。 |

**DEPLOY 中 `ctx.fetch` 的形态（2026-06-13 调整；触发条件 ADR-022 改为 imperative requestGraph）**：`ctx.fetch` 在 imperative 入口对所有档**一律存在**——目的是让错误送入的非 official context 拿到清晰的「权限不足」错误，而不是晦涩的 `TypeError`。但这不削弱 capability-based 保证：
- **档位由宿主据验签结果裁定**（非 adapter 自报），校验**在宿主边界 fail-closed**。
- DEPLOY 非 official 的 `ctx.fetch` 调用在拿到任何网络/凭证能力前即被拒；本地导入也不能绕过。
- DEV-Sideload 是显式全能力例外，可驱动核心使用开发者测试凭证；该放行由编译期 profile 隔离，不能据此推导 DEPLOY 放行。

**适用范围（ADR-024 / ADR-033）**：DEPLOY 的权威边界是 official grant，不是字节来源；非 official 在加载与宿主边界均被拒。DEV-Sideload 是正交全能力例外，未签名 context 与开发凭证放行由编译期 profile 隔离。优化等级与信任 profile 正交，不能以 `debug/release` 代称二者。

---

## 3. 已知约束与风险（Consequences，草案）

1. **最高敏感路径（红线 #1/#4）。** 实现与测试**不得 AI 独自闭环**；需安全检查清单 + 人工审阅（git.md §3、testing.md）。
2. **密钥管理是单点，已多重缓解。** 私钥泄露 = 信任根失守。缓解：① 私钥托管 **离线硬件 token（YubiKey）、永不导出、PIN+触碰本地签名**（§2.3，2026-07-15 修订）——失陷面从"偷走密钥"降为"物理窃取 token 且破 PIN"，且签名不在任何网络/CI 上、无远程出签面；② **多公钥预埋 + 分批启用**（§2.3）应对丢失（晋升备用）与泄漏（吊销收窄）——每把 YubiKey 各持独立密钥、全部公钥预埋，丢一把即晋升 dormant；③ kill-switch（§2.4）。残余风险：(a) 放大信任方向（晋升 dormant 公钥）**一律随发版**（不做热推启用声明），恢复速度受应用商店审核节奏制约；(b) 无云端逐次签名审计，改用 git 台账（§2.3）+ 人工纪律；(c) 单人持 token 是发布瓶颈/SPOF——用 ≥2 把 token（各自密钥、均预埋）+ 物理异地备份缓解；**(d) 首把 official 令牌 `elecon-official-ncc-1` 兼作维护者日常 GPG 签名令牌、日常随身携带**（2026-07-16 owner 决策），物理失窃暴露面高于专用离线令牌——缓解：窃得令牌者仍须破 PIN（3 次重试即锁）且**每签必须物理触碰**（`touch-policy=ALWAYS`），失陷后走吊销 + 晋升 dormant。**若日后引入专用离线令牌，应优先将其设为 active、把本把降为 dormant**；**(e)「所见非所签」**——§2.3 的「离线」指**不在任何自动化 / 云上**，签名本就发生在维护者**本地机**（非气隙），故被攻陷的本机可在触碰的瞬间替换待签载荷。`touch-policy=ALWAYS` 只保证「每一签都有人在场」，**不保证「签的是你以为的那个东西」**。这是本方案的**结构性残余风险**（KMS 方案同样有，只是换成"被攻陷的 CI 提交错载荷"）。缓解只能靠 ceremony 纪律：签前在**即将触碰的这台机器上**重算 digest 并与 CI 产出的 unsigned bundle 比对（§4 工作流），不可只看 CI 的输出。急性事件靠 kill-switch + 吊销兜。后续若需更快恢复可另起 ADR。
3. **community 档已砍（§2.1）。** 信任模型简化为 **official + sideload** 两档，维护者不再为"可分发性"背书，去掉了审查瓶颈。代价：社区贡献者要么自行 debug 侧载、要么经审查被收编为 official，**没有"已签名可分发但仍由社区维护"的中间态**。`community` 枚举值已于 2026-06-14 修订**从 `contract/manifest.schema.json` 与 ADR-001 §5 移除**（契约改动，红线 #6；向后兼容性见 §2.1——此前无生效验证路径，移除不放松约束）。`tools/scanner` 的 PII/危险 API 静态筛查仍对"收编 official 前的审查"有用，保留。
4. **离线/陈旧吊销的可用性权衡。** fail-closed 与"拉不到清单时仍可用上次良好状态"之间的策略已在 §2.4 定调（last-good 回退 + bundle 预置初始清单解全新安装的两难），避免吊销机制本身成为 DoS 面。残余权衡：预置清单的新鲜度受发版节奏限制，急性吊销仍依赖联网拉取 + kill-switch。
5. **签名规范化（canonicalization）已钉死规格（§2.3），残余风险在跨平台实现一致性。** 规则已固定（字典序/LF/UTF-8 NFC/二进制资产不变/Merkle-like 双层 SHA-256），但 Dart/Node/Wasm 三端的 NFC 归一化、路径排序（locale 无关排序）需跨平台 golden test 保证。
6. **与契约的边界。** `trustTier` 的 `community` 枚举清理已于 2026-06-14 修订**随本 ADR 一并落地**（§2.1，红线 #6，向后兼容）——这是经人工 owner 批准的契约改动，非"顺手改"。若日后需在 manifest 增签名/背书相关字段，仍另起独立 ADR。
7. **`ctx.fetch`"存在但档位校验"需下游一致性更新（§2.6）。** 此取向改了运行时 ctx 形态——[`adr_009`](./adr_009_fetch_credential.md) §2 决策 7、[`adr_008`](./adr_008_client_runtime.md) 客户端运行时及 declarative ctx 实现须一致。DEPLOY 非 official 仍 fail-closed；DEV-Sideload 全能力例外由编译期 profile 隔离。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

> 安全敏感项标（人工主导、AI 仅辅助）：

- ~~`tools/src/signer`~~ **✅ 已落地（2026-07-16 真机核验）**：bundle 规范化（§2.3 规格：字典序/LF/UTF-8 NFC/双层 SHA-256）+ **Ed25519 签名经离线 YubiKey 后端**（`YubiKeySignBackend` → `YubiKeyPkcs11Signer`，PIV/PKCS#11 `CKM_EDDSA`，私钥驻留硬件、不入仓；开发阶段可用 `LocalDevSignBackend` 软密钥）/ 验签 + 吊销清单生成。签名管线细节见 [`adr_018`](./adr_018_adapter_distribution.md)；ceremony 见 [`signing_ceremony.md`](../reference/signing_ceremony.md)。
- **新依赖声明（红线 #9）**：`pkcs11js`（**MIT**）——PKCS#11 2.40 的 Node 绑定，仅供 `tools/src/signer/pkcs11.ts` 在**离线签名机**上驱动 YubiKey；**不进客户端 / 服务端二进制，不随 [`adr_018`](./adr_018_adapter_distribution.md) §2.8 的镜像发布**。定为 **`optionalDependencies`**：它是原生模块（node-gyp），而 CI / 普通开发机既无令牌也未必有构建工具链——惰性 `import` + fail-closed，缺它时 validator / scanner / digest / 验签均不受影响。MIT 与红线 #9 的 GPL 传染性隔离要求无冲突。
  - 实现注意（已在代码内注释钉死）：`pkcs11js` 只实现到 **PKCS#11 2.40**，而 Ed25519 相关机制是 **3.0** 才引入的（`CKM_EDDSA`=0x1057、`CKM_EC_EDWARDS_KEY_PAIR_GEN`=0x1055）——**须自行定义常量**。且该包是 CJS、常量动态赋值到 `module.exports`，ESM `import` 拿不到（全为 `undefined`，症状伪装成参数类型错），须取 `default`。
- **离线硬件签名工作流**（取代原 OIDC→KMS 管线）：CI/审查沙箱只产出 **unsigned bundle + digest**；维护者本地重算 digest 确认一致 → YubiKey PIN+触碰签 → 提交 `signature.json` + 更新发布台账。签名不在任何自动化上。实现注意：须取**裸 64 字节 Ed25519 签名**（PIV/PKCS#11，非 OpenPGP packet 封装）以对齐现有验签——`YubiKeySignBackend` 与 `YubiKeyPkcs11Signer` 两处均有 64B 守卫（纵深防御）。**「本地重算 digest 比对」是 §3 风险 2(e)「所见非所签」的唯一防线，不可省。**
- 可信核心：DEPLOY 加载前验签（active pin）+ 吊销 + 签名裁定档位 + `ctx.fetch` 档位校验（非 official → 结构化权限错误、永不触达注入）；DEV-Sideload 的显式放行分支单独隔离。客户端与服务端核心共享裁定语义。
- **多公钥预埋 + 分批启用**：active/dormant 公钥集合；晋升（应对丢失）/ 停用（应对泄漏）方向不对称（§2.3）；**晋升与集合增删一律随 App 发版**（不做热推启用声明）。
- `tools/` 校验器：补 requestGraph 与能力专属静态检查。当前保留 `sideload + imperative` C3；ADR-033 提议退役，接受时须同批补 DEPLOY official-only 负例，不得只删断言。
- 侧载闸门：ADR-033 接受前仍确保全部本地导入入口从 DEPLOY 剔除；接受后改为确保 **devSideload grant、未签名执行与 DEV 凭证放行路径**从 DEPLOY 剔除，同时 DEPLOY 本地入口只汇入 official verifier + 在线治理门。DEV 形态为独立应用身份 + 启动持久警告 + 全占用确认。🔒 安全敏感，人工主导。
- 吊销分发：公网哑服务托管签名吊销清单；核心拉取/验签/回退策略。
- 测试：验签正/反例、谎报档位提权反例、**DEPLOY** `ctx.fetch` 非 official 拒绝、**DEV-Sideload** 未签名 imperative 放行但凭证值不可见、公钥晋升/停用、吊销与规范化；安全敏感测试人工编写或实质审阅。
- 契约：`trustTier` 枚举 `community` 清理**已于 2026-06-14 修订落地**（`contract/manifest.schema.json` + ADR-001 §5，红线 #6，向后兼容见 §2.1）。manifest 签名字段如需新增另起独立 ADR。
