# ADR-033：双 profile 本地导入（DEPLOY official-only / DEV 全能力侧载）

- **状态**：**已接受（Accepted）** · 2026-08-10 owner 评审通过。决策过程逐轮保留于 §1（不作一次性拒绝）。**已接受但尚未落地**：实现按 §5 连带清单推进，落地前现有 DEPLOY 零本地导入实现与 ADR-024 gate 仍是运行基线——这是实现进度，不再是 ADR 状态闸门。
- **日期**：2026-08-09（2026-08-10 两轮反馈后重写）
- **适用范围**：adapter bundle 的本地导入渠道、DEPLOY/DEV profile 的加载门禁、吊销新鲜度、设置入口与 `trustTier: sideload` / validator C3 的去留。
- **不含**：transport 侧载（仍禁止）、签名密码学与私钥流程本身（ADR-002/018）、新 capability 或凭证契约（须另走 ADR）。
- **触及红线**：#1（凭证永不离开核心）、#4（DEPLOY 加载入口）、#5（adapter 能力面）、#10（架构性改动先写 ADR）
- **依赖**：ADR-002、ADR-010、ADR-018、ADR-022、ADR-023、ADR-024。

---

## 1. 决策过程

### 1.1 初稿：DEPLOY 声明式未签名侧载

2026-08-09 初稿提议：iOS 保持零侧载，Android/桌面允许未签名、declarative-only 的生产侧载，并增加 dataflow、域名与告知闸门。其动机是降低新学校 adapter 等待 official 审查和签名的供给瓶颈。

审查发现，`declarative` 已可通过 `bind` → `compute` → `inject` 控制跨请求数据流；仅凭“没有 `ctx.fetch`”不能证明未签名代码无法驱动敏感数据外送。初稿因此需要一套额外的生产低信任运行时，复杂度和证明负担过高。

### 1.2 第一轮反馈：改为 DEPLOY 零侧载

2026-08-10 第一轮反馈倾向彻底拒绝生产侧载，改为所有平台 `DEPLOY = 零侧载`、`DEV = 唯一侧载环境`。该方案能力面最小，但把“分发渠道”和“运行时信任档”捆在一起：即使 bundle 已有 official 签名、可通过吊销校验，也无法由用户从本地文件恢复、测试或安装。

### 1.3 第二轮反馈：打回修改，不作一次性拒绝

owner 最终要求继续保留两种本地导入，但严格区分：

- **DEV-Sideload 是开发工具**：侧载全部允许，不限制为 declarative；
- **DEPLOY 本地导入是 official 的另一条输入渠道**：只接受通过 official 签名与远端吊销校验的 bundle，导入后信任档仍是 official；
- DEPLOY 入口放在设置中的低频高级项，避免成为日常动线，低可达性只减误触，不承担安全边界。此路径安全边界由adapters签名承担。

本文据此重写，并于 2026-08-10 由 owner 接受。

---

## 2. 术语：渠道与信任档必须分开

“侧载”容易同时指两件事，本文强制拆开：

1. **本地导入渠道（local import）**：bundle 字节来自用户选择的本地文件，而非 catalog/CDN 自动下载；
2. **运行时信任档（trust tier）**：核心根据验签结果裁定 bundle 能获得什么能力。

因此：

- DEPLOY 可以有本地导入渠道，但导入的 bundle 必须被裁定为 `official`；
- `trustTier: sideload` 只表示 DEV 中未签名/非官方签名的开发素材；
- “从本地文件导入”不等于“按 sideload trust tier 运行”；
- manifest 自报 `official` 仍不能提权，权威档位只来自核心验签。

---

## 3. 决策

### 3.1 profile 矩阵

| profile | 本地导入 | 可接受 bundle | requestGraph / 能力 | 分发 |
|---|---|---|---|---|
| **DEPLOY** | 有，设置内高级项 | **official 验签 + 身份绑定 + 在线 catalog/revocation + 吊销/版本/stdlib/schema 全门禁** | 与 catalog 安装的 official 完全相同 | 正式用户产物 |
| **DEV-Sideload** | 有，开发入口 | official 或未签名 DEV 素材 | **全部允许**：declarative、imperative 及当前宿主已编入的敏感能力 | 仅开发者，**不可分发** |

两者都不新增 trust tier。DEPLOY 本地导入成功后铸造的是既有 `official` grant；DEV 未签名导入铸造的是既有 `devSideload` context。

### 3.2 DEV-Sideload：全部允许

DEV-Sideload 的职责是调试 adapter，而不是模拟低信任生产沙箱。因此：

- 未签名 adapter 可混用 declarative / imperative requestGraph；
- 不受sequence防回滚影响，不验证签名以及吊销列表。
- 可调试登录、凭证收割、ssoMint、dataflow、action 等**当前 DEV 宿主已编入**的能力；
- imperative 可通过 broker 使用开发者自有测试账号的凭证；凭证值本身仍不得离开核心（红线 #1 不因 DEV 失效）；
- 强启动警告、独立 applicationId/bundle ID、每 adapter 首次全占用确认和“不可分发”标记继续保留；
- DEV 可使用优化的 `--release` build；优化等级不决定信任 profile；
- DEV 不是“declarative-only sideload”，所有此类表述均废止。

#### C3 处置

退役 `C3_sideload_must_declarative`：

- 它会阻止 imperative adapter 作为 DEV/社区素材被完整预检，与 DEV-Sideload 的调试职责冲突；
- official 签名流程应审查最终 bundle 的真实能力，而不是要求待签素材先伪装成 sideload declarative；
- 签名 ceremony 输出的权威档位是 official，DEPLOY 能力由 official 签名、人工审查和运行时宿主门禁承担；
- validator 仍须校验 requestGraph 结构、域名白名单、凭证引用、capability registry 与所有能力专属规则，但不再以 `trustTier: sideload` 一刀切禁止 imperative。

这是 validator 行为修订，不删除 manifest 的 `trustTier: sideload` 枚举。落地前须补 C3 删除的正反例，并人工复核不存在把 manifest claim 当成权威档位的路径。**在该批测试与复核完成前，现有 C3 不得先删。**

### 3.3 DEPLOY：official-only 本地导入

DEPLOY 设置页可让用户显式选择本地 bundle 文件。导入必须按以下顺序 fail-closed：

1. **只接受显式文件选择**：无 deep link 自动导入、无文件关联自动执行、无任意 URL 下载框、无后台扫描目录；
2. **解析上限与格式校验**：在验签前限制压缩包字节数、单文件与累计解压字节数、文件数和嵌套深度；拒绝绝对路径、`..`、重复路径、规范化后碰撞、链接及 envelope 允许集之外文件；再做 schema/version 检查。任一超限/畸形立即拒绝，解压不得无界落盘；
3. **official 验签**：使用内置 active official pin 验证签名、digest、adapterId/version 与裁定档位；非 official、未签名、自报 official 或 dormant/未知 key 一律拒绝；
4. **在线刷新远端治理材料**：从固定官方端点拉取 catalog 以及 revocation，验证签名、TTL 与 sequence 单调性；网络失败、签名失败、回滚、过期、同 sequence 不同字节（equivocation）或无法确认新鲜度时，本次导入失败，**不得仅凭本地 last-good 完成新导入**；
5. **治理高水位独立提交**：一旦新 catalog/revocation 通过签名、TTL、sequence/equivocation 校验，须在检查候选 bundle 前分别原子持久化其原始签名字节与 sequence 高水位。即使候选随后因吊销/版本不符被拒，也不得丢弃已见的新治理状态；后续旧 sequence 永远拒绝。治理 last-good 与 adapter last-good 是两个事务，禁止共用“候选失败则全部回滚”的语义；
6. **catalog 与降级门**：catalog 的权威字段是 adapterId/version/digest/stdlibMin/capabilities；revocation 的权威字段是 key kill-switch、撤销范围与 minVersion。若 catalog 有同 adapter 条目：候选版本不得低于 catalog 版本；同版本 digest 必须一致；候选 capabilities 不得与签名 manifest/registry 冲突。若 catalog 无该 adapter，可凭 official 签名继续，但仍受 revocation。候选版本还不得低于当前已安装版本或 revocation minVersion；本 ADR 不提供降级/回滚例外；
7. **吊销与兼容门**：检查 key kill-switch、adapterId/version/digest 吊销、`stdlibMin`、schema 与 capability registry；任一不满足即拒绝；
8. **原子安装**：候选校验全过后写临时区，持久化来源=`local-import`、bundle digest、验证时 catalog/revocation sequence，再原子切换 adapter last-good；候选失败不得污染已安装 adapter，但不得回滚第 5 步已提交的治理高水位；
9. **每次启动仍走统一 loader**：本地导入只改变字节来源，不绕过既有验签、吊销和 stdlib 门。

“远端吊销后才能侧载”在本文中具体解释为：**每次新增或更新本地导入都必须成功在线取得并验证新鲜治理材料**。已安装 bundle 的离线启动是否继续沿用 ADR-002 的 last-good/TTL 规则不在本次放宽范围内，仍按既有 loader 语义。

### 3.4 设置入口与告知

DEPLOY 入口位于：`设置 → 高级 → 本地导入官方 adapter`。要求：

- 不放首页、adapter 缺失提示或登录主流程；
- 不用系统文件关联、分享菜单或 deep link 暴露快捷入口；
- 进入页先说明“仅接受 Elecon official 签名包；导入前必须联网检查吊销”；
- 文件选择后展示 adapterId、version、签名 keyId、digest、声明域名和来源路径，再由用户确认；
- 明确错误区分：未签名/非 official、签名失败、无法联网检查吊销、已吊销、版本/stdlib 不兼容。

入口低可达性只是防误触和避免形成“插件市场”观感；真正安全边界始终是验签、在线治理材料、吊销与统一 loader。UI 隐藏绝不能替代机制校验。

DEV 入口可更直接，但必须保留不可关闭的 DEV 身份提示与风险确认。

### 3.5 分发与吊销语义

- catalog/CDN 仍是默认安装与更新渠道；本地导入是显式备用渠道，不允许配置第三方 catalog；
- 本地导入包不要求已出现在 catalog 中，因为 official 签名本身是发布授权；未收录时 catalog 仅提供已验签的新鲜治理高水位，候选仍受 revocation/kill-switch；
- 本地导入不能固定旧版本或降级到低于当前安装/catalog/minVersion 的版本；同 adapter/version 若已在 catalog，digest 必须一致；
- official 私钥仍不上服务器/CI，本地导入不改变签名 ceremony；
- DEPLOY 不接受 community key、自签 key、用户自定义 CA/key 或“仅 declarative 所以放行”的例外。

---

## 4. 安全与合规分析

### 4.1 相比初稿为何更安全

初稿试图让未签名 declarative adapter 进入 DEPLOY，必须另造 G1-G6 能力子集。新方案不让任何未签名/非 official 代码进入 DEPLOY：本地文件与网络下载最终汇入同一 official loader，避免维护第二套生产能力模型。

声明式 dataflow 的外泄分析仍保留为决策依据：它证明“declarative-only”不足以替代签名和审查，但不再需要为 DEPLOY 本地导入裁剪 dataflow，因为导入包已经是 official。

### 4.2 新增风险

1. **入口代码进入 DEPLOY**：ADR-024 原“侧载入口符号为零”不再成立，gate 必须改成证明“未签名/devSideload 铸造与凭证放行路径为零”，并测试 DEPLOY 本地导入只汇入 official verifier。
2. **解析攻击面前移**：攻击者可喂任意本地文件，故格式/大小/路径校验须在昂贵解析和写盘前 fail-closed。
3. **远端治理可用性**：导入时强制联网会牺牲离线安装，但避免用陈旧 last-good 接受已吊销包；本文选择安全优先。
4. **App Store 解释成本**：iOS 也保留本地导入时，ADR-010 的“物理无侧载入口”论证必须改写为“无第三方代码市场：只接受项目 official 签名且受远端吊销治理”。接受本文前须人工复核 DPLA §3.3.2 论证。
5. **误发 DEV 包**：DEV 允许全部能力，误发后果更重；独立应用身份、水印与 release gate 必须保留，DEPLOY gate 必须能拒绝 DEV profile。

### 4.3 不变量

- 凭证值与等价物仍不离开核心；
- DEPLOY 永不运行未签名或非 official adapter；
- manifest `trustTier` 仍只是 claim；
- 本地导入不绕过签名、吊销、最低版本、stdlib 与 capability schema gate；
- transport 仍无任何侧载入口；dev transport 仍仅 debug build 存在；
- DEV 全能力例外不进入 DEPLOY 的未签名运行路径。

---

## 5. 连带修订与落地闸门

本文已接受。**文档修订（1–5）随接受一并完成；实现（6–8）尚未开始，须同批落地，不得只落其中一项。**

| # | 项 | 状态 |
|---|---|---|
| 1 | 修订 ADR-002 §2.5/§2.6：渠道与 trust tier 分离，DEV 全能力，DEPLOY local import official-only | ✅ 文档已改 |
| 2 | 修订 ADR-022/001：记 C3 退役，保留 per-capability requestGraph 结构校验 | ✅ 文档已改 |
| 3 | 修订 ADR-024：从“DEPLOY 无入口”改为“DEPLOY 无 devSideload/未签名路径”，gate 哨兵待重做 | ✅ 文档已改 |
| 4 | 修订 ADR-010：iOS 论证改写；**iOS 实现仍待人工/Apple 合规复核**（§6 开放问题 1） | ✅ 文档已改，合规复核未做 |
| 5 | 修订 ADR-018：新增本地文件这一 official bundle 字节来源，不新增信任域或签名档 | ✅ 文档已改 |
| 6 | validator 退役 C3，同批补 DEPLOY official-only 负例 | ⬜ 未开始（C3 仍在位） |
| 7 | DEPLOY official 本地导入实现 + 在线治理门 + 新 release gate 断言 | ⬜ 未开始（仍为零入口 gate） |
| 8 | 为 Android、iOS、macOS、Windows、Linux、OHOS 补产物与入口测试 | ⬜ 未开始（仅 Android 有旧基线证据） |

第 6–8 项属安全实现，须人工主导 + 安全清单 + 至少一名人工审阅，**AI 不得独自闭环**。

**落地纪律**：本文已接受，但落地前代码仍保持 ADR-024 的 DEPLOY 零本地导入 gate 与现有 C3——**接受授权了实现，不等于实现已存在**。任一项单独落地都会造出「文档说 official-only 导入、代码却没有对应门禁」的错配，故须按 §5 第 6–8 项同批推进，并遵守其人工闸门（AI 不得独自闭环）。

---

## 6. 落地前须解决的开放问题

本文已接受，但下列问题必须在对应实现落地**之前**逐条有答案；它们不阻塞本 ADR 的状态，阻塞的是各自那部分实现。

1. iOS 本地 official 导入是否足以维持 DPLA §3.3.2(b)“非代码市场”论证，是否需要平台例外？本文倾向全平台一致，但须人工合规复核。
2. official 签名但尚未进入 catalog 的 bundle 是否允许导入；本文规定允许，但必须通过最新 revocation，且不得降级当前已安装版本。
3. 本地导入文件格式是否直接复用 ADR-018 envelope，是否需要单文件封装；实现前须固定路径/大小上限。
4. 新 gate 如何机械证明 DEPLOY 不含 `devSideload` grant 铸造与未签名执行路径，而不是只检查一个可绕过的哨兵字符串。

---

## 7. 修订记录

| 日期 | 阶段 | 决策过程 |
|---|---|---|
| 2026-08-09 | 初稿 Proposed | Android/桌面允许未签名 declarative-only 生产侧载，iOS 零侧载；因 dataflow 外泄面增 G1-G6。 |
| 2026-08-10 | 第一轮反馈 | 倾向拒绝初稿并改为全平台 DEPLOY 零侧载；识别到该方案把渠道与信任档捆绑。 |
| 2026-08-10 | 第二轮反馈 | 不作一次性拒绝，打回重写后待审：DEV-Sideload 全能力；DEPLOY 保留设置内本地导入，但只接受 official 签名且每次导入强制在线吊销治理。 |
| 2026-08-10 | 正式同意 | 修改验证签名等表述，检验物料等修正 |
| 2026-08-10 | **接受（Accepted）** | owner 同意全文并收敛各处引用表述：状态由 Proposed 转 Accepted，跨文档「接受前不得实现」一律改为「已接受、待按 §5 落地」。实现尚未开始。 |
