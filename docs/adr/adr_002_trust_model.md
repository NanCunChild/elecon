# ADR-002：插件信任模型（签名 / 吊销 / dev 侧载闸门）与能力分档（official / sideload）

- **状态**：已接受（Accepted） 2026-06-13 经人工安全检查清单全项确认后接受。实现仍须按 AGENTS.md §1 人工主导（红线 #1/#4/#5 承重路径）。
- **日期**：2026-06-11（历次修订 2026-06-12 · 06-13 · 06-13b · 06-14 · 07-15 · 07-16 · 09-08 · 09-09）
- **签收**：**§2.3 digest v2 规格于 2026-09-09 由 owner NanCunChild 正式签收**（已接受并完成审阅）。签收范围为规格；实现触红线 #4，落地后仍须单独人工复核。
- **修订流水**：各次修订的动机、取舍与**人工批准记录**已迁至 [`docs/archive/adr_002_revision_log.md`](../archive/adr_002_revision_log.md)；本文正文只承载**当前生效的决策**。
- **状态源约定**：本文只承载决策；**落地与安全签收**的待办态一律只存在于 [`README.md`](./README.md) 索引表与 [`2026_08_review_remediation.md`](../planning/2026_08_review_remediation.md)，正文不重复记录（同 ADR-001 约定）。
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§2.2 可信核心、§3.3 凭证边界、§3.4 传输底座）、[`adr_001_contract.md`](./adr_001_contract.md)（§5.2 信任档字段；community 策略原留给本文细化——本文**决定砍掉**，见 §2.1）
- **被依赖**：[`adr_009`](./adr_009_fetch_credential.md)（imperative requestGraph 凭证注入，trust tier 由本文裁定）、[`adr_003`](./adr_003_transport.md)（传输底座抽象；**仅在 §2.4 的远端治理面上依赖本文**——transport 的签名/验签/吊销已于 2026-09-09 作废，它编译期编入二进制、无加载门，见 ADR-003 §2.3）、[`adr_018`](./adr_018_adapter_distribution.md)（adapter 分离/审计/打包/分发 + 解释器版本同步——落地本文 §2.3 的签名管线与 §2.4 的清单分发）；并为 [`adr_010`](./adr_010_ios_appstore.md) 的 App Store 合规论点 (b)「非代码市场」提供支撑（无侧载入口 + 仅签名分发）。
- **适用范围**：adapter（QuickJS 脚本）与传输底座（原生模块）的**信任建立、能力分档、分发与吊销**。**不含** 凭证注入的具体脱敏机制（另文）、UI 信任（不在此）。

---

## 1. 背景（Context）

ADR-000 §2.2 把"签名校验、吊销、dev 侧载闸门"定为可信核心的职责，§3.3/§3.4 给了三档能力分级与"传输底座仅官方签名"的方向，但没定**机制**。ADR-001 固定了 manifest `trustTier` 字段（official / community / sideload）并明确把 **community 策略与签名机制留给本文**。`tools/src/signer` 目前是 stub。

需要回答的核心问题：**凭什么相信一个 adapter？相信到什么程度（能拿凭证吗？能进 release 吗？）？怎么撤回信任？**

红线约束（承重墙，不可违背）：
- #1 凭证永不离核心 → 只有最高信任档才有资格触发凭证注入。
- #4 **DEPLOY 仅运行官方签名 adapter**：无论 bundle 来自 catalog 还是本地文件，都只运行通过 official 验签、身份绑定与吊销门禁的 adapter；不得存在未签名 / 非 official 的加载路径。
  > 该红线**原标题**为「传输底座仅官方签名加载」，其中关于 transport 的部分已于 2026-09-09 作废（owner 决策，见 ADR-003 §2.3）：transport 编译期编入二进制、无加载门。**红线正文自始只约束 adapter，故编号与内容保留不变**；dev 传输仅 debug build 这一条改由**编译期门控**承担（ADR-003 §2.3 第 1 条 / [`adr_024`](./adr_024_build_profile_trust.md) §3）。
- #5 **adapter 能力面越薄越好**（约束能力/信任面，非功能复杂度）。其硬约束：DEPLOY 永不运行未签名 / 非 official adapter；DEV-Sideload 是全能力调试例外，凭证值仍不离核心，见 §2.5。DEPLOY 本地 official 导入与 C3 退役由 ADR-033 决定（已接受，尚未落地）。

---

## 2. 决策（Decision）

> 本节为**已接受的决策**（见头部状态；§2.3 digest v2 规格另经 2026-09-09 单独签收）。
> 「已接受」指**规格**已定；触红线 #1/#4 的**实现**仍须逐次人工复核（AGENTS.md §1）。

### 2.1 两个正交维度：签名管「分发」，信任档管「能力」

把两件常被混为一谈的事拆开：

- **是否通过 official 验签** → 决定**能否在 DEPLOY 运行**。字节可来自 catalog，或在 ADR-033 接受后来自用户显式本地导入；来源不改变 trust tier。未签名 = 仅 DEV-Sideload。
- **信任档** → 决定**能做什么**（能力上限）。

| 档 | 建立方式 | 分发 | 能力上限（DEPLOY） | 能力上限（DEV profile） | 执行落点 |
|---|---|---|---|---|---|
| **official** | 一方编写或深度审查 + 项目签名 | DEPLOY（catalog；ADR-033 增加本地文件来源，待落地） | **imperative / declarative requestGraph**、当前正式宿主能力 | 同 DEPLOY | client-direct / campus-relay |
| **sideload / devSideload** | 开发者本地加载，**无签名** | **仅 DEV-Sideload，不可分发** | —（DEPLOY 不运行此档） | **任意 adapter**（imperative / declarative 一视同仁，见 §2.1.1）+ 当前 DEV 宿主已编入能力；须强警告 + 全占用确认 | DEV 专用 |

**DEPLOY 下凭证注入（imperative requestGraph；旧称 fetch 模式，见 ADR-022）是 official 独占**——把最高风险面锁死在项目授权代码上。**DEV-Sideload 例外**：无签名 adapter 可调试 imperative 及当前 DEV 宿主能力、可触发开发者测试凭证注入；以多重警告兜底，未签名 grant 与 dev 凭证放行路径编译期不进入 DEPLOY。ADR-033 的 DEPLOY 本地导入即使落地，也只铸造 official grant，不改变此不变量。

#### 2.1.1 Sideload 的能力面：**任意 adapter**（2026-09-08 owner 决策，消歧）

本文此前把这件事分散在 §2.1 表格、§2.5 与 §2.6 三处，且每处都挂着「ADR-033 已决定退役 C3、尚未落地」的限定语，读者无从判断「sideload 只能 declarative」是**当前决策**还是**待改的遗留**。故在此钉死：

> **Sideload 可以加载任意 adapter，declarative 与 imperative 一视同仁。requestGraph 的声明性不是信任维度，从来都不是。**

- **为什么**：sideload 的安全边界是 **profile 隔离 + 用户显式确认**，不是「阉割 adapter 的表达能力」。用 declarative-only 限制 sideload，既拦不住真正的攻击面（declarative 的请求配方一样能打白名单内的任意端点、一样能拿到脱敏后的私密响应），又让 DEV 环境**调试不了 DEPLOY 实际会跑的那份 adapter**——开发环境与生产环境的语义分岔，这本身就是缺陷来源。
- **真正的信任维度只有一个**：**是否通过 official 验签**。它决定能否在 DEPLOY 运行。DEV-Sideload 是与之正交的全能力开发例外，由编译期 profile 隔离。
- **不变的部分**：凭证值仍不离核心（红线 #1，DEV 亦然）；侧载产物不可分发；DEPLOY 永不运行未签名 / 非 official adapter（红线 #5）。**本条只澄清 sideload 内部不按 requestGraph 分级，不放松任何 DEPLOY 约束。**
- **与实现的关系**：validator 的 `C3_sideload_must_declarative` 是**与本决策相悖的遗留断言**，不是当前规则的表述。它的移除由 [`adr_033`](./adr_033_production_sideload.md) §5 统一编排，须与 DEPLOY official-only 负例**同批**落地——**在此之前 C3 仍会开火，那是落地进度，不是决策内容。** 🔒 该批落地触红线 #5，须人工主导 + 安全清单 + ≥1 人工审。

**community 档已砍（2026-06-13 决定）**：原拟的 community 与 sideload 能力上限相同（都 declarative-only），背书签名只买到「能经官方渠道分发」，代价却是**维护者须逐个审查并背书**——正是 ADR-000 要消除的人工瓶颈。权衡后**取消 community 档**：信任模型只剩 **official** 与 **sideload** 两档。社区贡献的 adapter 一律走 **sideload**（贡献者自行 debug 加载，或经审查被收编为 official）；**官方维护 / 深度审查的 adapter 一律 official**。这把维护者从"为可分发性背书"的责任里解放出来，与「最小人力」主线对齐。代价：**没有"已签名可分发但仍由社区维护"的中间态**——可分发即官方背书。核心**无 community 验证路径**，任何自报 community 的包按 sideload 处理（§2.2）。**契约清理（2026-06-14 人工 owner 决策）**：`community` 枚举值**从 `contract/manifest.schema.json` 与 ADR-001 §5 彻底移除**（不再保留枚举位）。这属契约改动（红线 #6），向后兼容性说明：`community` 此前**无任何生效验证路径**（运行时一律按 sideload 处理），移除后自报 `community` 的 manifest 在 `tools/` 静态校验阶段即被拒——行为从"运行时降级"前移为"加载前拒绝"，不放松任何安全约束。

### 2.2 信任档由「签名背书」裁定，不信任 manifest 自报字段

manifest 里的 `trustTier` 只是**声明（claim）**，不是依据。**权威信任档来自核心对签名/背书的验证**：

- 一个侧载包把 `trustTier: "official"` 写进 manifest **不能**提权——核心验不到对应签名；DEPLOY 直接拒绝，DEV 才可按 sideload 本地加载。
- 签名载荷**覆盖** `adapterId` + `adapterVersion` + 内容哈希 + **裁定档位**（两档制下即 official；无签名 = sideload），使档位不可伪造。核心以"验签得到的档位"为准；与 manifest 自报不符则拒绝加载（fail-closed）。

- **意图档位由签发流水线显式给出，不向 manifest 提问（2026-09-01 修订）。** 上面两条说的是「运行时
  不信 claim」，但校验与发布**工具链**此前一直在读 `manifest.trustTier` 来驱动三道敏感能力闸门
  （validator 的 `C3_sideload_must_declarative`、`M5_via_requires_official`、`RM2_official_only`），
  发布流水线 `release/package.ts` 更是以「manifest 是否自称 official」作为准入判断——**等于把 claim
  当成了判据**，与 §2.2 的原则自相矛盾。故：

  - 新增**意图档位**（`IntendedTier`）作为校验器与发布流水线的**显式入参**。它不是信任档
    （信任档仍只由 official 签名裁定），而是「本次校验按哪一档的规则来审」。
  - 三道闸门一律读该入参。`release/package.ts` 一律以 `"official"` 调用校验，与其
    `signEnvelope(env, "official", …)` 同源——**发布意图由流水线声明，不由被发布物自述**。
  - `manifest.trustTier` 从 `required` 移出（保留字段与枚举），降为**过渡期回退**：
    未给入参时回退到 claim 并产出 warn（`C0_intended_tier_implicit`）；两者皆缺则 fail-closed
    取 `sideload`（`C0_intended_tier_defaulted`）；**两者分歧则 error**（`C0_intended_tier_mismatch`）
    且**以入参为准**——claim 永远不能把校验放宽到比流水线声明更松。
  - **为何保留回退而非直接强制**：档位是**逐 adapter**的，而 `npm run validate` 不带 `--adapter=`
    时做发现式全量扫描，单个全局 flag 表达不了逐个 adapter 的意图。故 `--intended-tier=` 只允许与
    `--adapter=` 同用；发现式扫描继续回退并以 warn 暴露。回退的移除随
    [`adr_033`](./adr_033_production_sideload.md) 落地。
  - **本次不删 `C3_sideload_must_declarative`**，只改它的输入来源。ADR-033 §5 要求 C3 退役须与
    DEPLOY official-only 负例同批落地、不得抢跑，该约束不变。
  - 红线 #6：`contract/manifest.schema.json` 的 `required` 减少一项属**放宽**，既有 manifest 全部
    继续合法，无迁移。

### 2.3 签名机制

> **作用域声明（ADR-000 §2.3.1）**：**本节所称 envelope / 信封，一律指「bundle 信封」**——adapter 包的清单 + 签名对象（[`adr_018`](./adr_018_adapter_distribution.md) §2.9.1）。与运行期的 **数据信封**（`elecon.envelope`，[`adr_001`](./adr_001_contract.md) §3.3）、与 [`adr_012`](./adr_012_credential_store.md) §2.8 的 **信封加密** 无关，只是撞名。承载它上线的三字段外层对象称 **传输封套**，不叫信封。

- **签什么**：adapter bundle 的 **digest v2** = `SHA-256(bundle 信封序列化字节)`（定义见 [`adr_018`](./adr_018_adapter_distribution.md) §2.9.1）+ **裁定档位**（§2.2），detached 签名。传输底座二进制同理。
- **方案**：**Ed25519**（RFC 8032）签名 over bundle 内容摘要。注意 **Ed25519 内建哈希固定为 SHA-512、不可参数化**——所以"Ed25519 over SHA-256"是范畴错误；这里的 **SHA-256 仅指 bundle 内容摘要**（签什么），与 Ed25519 内部的 SHA-512（怎么签）是两处独立的哈希。
- **digest v2：envelope 降为「清单」，签其序列化字节（2026-09-01 修订，取代原「双层 SHA-256 拼接」）。**

  **为什么改**：v1 的 digest 只哈希「按路径排序后的内容」，**路径自身从不进哈希**，而加载器按路径取要执行的字节 → **保序重命名**可让 official 签名背书「受审时叫 `assets/theme.css`、改名后叫 `index.js`」的内容被执行，检出率为零，直接击穿红线 #4。病根是 envelope 同时当**容器**和**清单**，唯一没被签的字段恰是 `path`。v2 把容器拆出去，**envelope 只做「清单 + 签名对象」**：

  > v1 规格全文、攻击复现、以及四种被否方案（四元组叶子编码 / Merkle / 签压缩包字节 / 内联 base64）的论证，见 [`归档：digest v1 与决策过程`](../archive/bundle_digest_v1_superseded.md)。可执行证据：`tools/src/bundle/path-binding.smoke.ts` A 组（落地前名为 `path-binding.redcase.ts`，全绿后改名纳入 `smoke:all`）。

  ```jsonc
  // envelope —— 签名对象。小、可读、可人眼审完
  {
    "bundleFormat": "elecon-bundle/3",   // 2026-09-12 起（ADR-026 §2.7.1 masker 断代）
    "adapterId": "school-xidian",
    "adapterVersion": "0.3.1",
    "files": [
      { "path": "index.js",      "size": 4211, "sha256": "9f2c…" },
      { "path": "manifest.json", "size":  812, "sha256": "3ab0…" },
      { "path": "masker.json",   "size":  147, "sha256": "c751…" }
    ]
  }

  digest = SHA-256( envelopeBytes )            // envelopeBytes = UTF-8(JSON(envelope))
  ```

  文件字节改由**按内容哈希寻址**的 blob 表承载（见 [`adr_018`](./adr_018_adapter_distribution.md) §2.9.1 的上线形态）——**不按路径寻址**，故仍是纯 JSON、🔒 加载器零自研归档解析（当初弃 tar 的理由完好）。

  **descriptor 形态换来的三件事**（论证见归档 §2.4）：① **编码离开信任边界**——内容按 `sha256` 内容寻址，两端 base64 解码器的宽严差异从**信任问题**降级为**传输问题**；② **签名对象小到人可审完**——这使 §3 风险 (e)「所见非所签」的唯一防线（离线机重算 digest 比对）从名义存在变为可执行，**这是本次修订最实在的收益**；③ 台账可记录 envelope 全文，P0-15 对账落到逐文件粒度。

  **身份三方一致（§2.2 的加强）**：envelope 顶层新增 `adapterId/adapterVersion`，核对从两方改为**三方**——`签名载荷` ↔ `envelope 顶层` ↔ `manifest.json 内容`，任一不符即 fail-closed。`manifest.json` 仍是运行时策略（`network.allow` / `credentials` / `runtime.entry`）的唯一权威源，envelope 顶层身份**只用于核对，不用于裁定**。

  **不可分割的配套纪律**（缺一条即退化；实现细则与验证顺序见 [`adr_018`](./adr_018_adapter_distribution.md) §2.9.1）：

  1. **签名对象以不透明字节上线。** on-wire 携带 envelope 的 base64 串，验端哈希**收到的那一串**。任何路径下都不得「解析成对象 → 重新序列化 → 再哈希」——那等于把 canonical JSON 的全部漂移面（键序、Unicode 转义、数字格式、重复键）请回来。这与 JWS 签 `BASE64URL(payload)` 而非签 JSON 对象是同一条理由。
  2. **验签先于解析。** 有界 gunzip → 取 envelope 字节 → 验签 → **才** `JSON.parse`。验签前允许解析的只有那个三字段的**传输封套**（ADR-018 §2.9.1）。
  3. **卫生闸门在验签之后。** 签名只证明「发布者确实想要这些路径」，**不**证明这些路径安全；哈希再多字节也不会让 `../../` 变安全。重复路径、绝对路径（含 Windows 盘符）、`.`/`..` 段、反斜杠、空路径、尾随分隔符、NUL 一律 fail-closed。**重复路径不是纯纵深防御**：Dart `List.sort` 不保证稳定而 TS `Array.sort` 保证，同名条目会造成跨语言分歧（§3 风险 5）。

     > **2026-09-09 落地时改判（🔒 待 owner 签收）：路径段字符集收紧为 `[A-Za-z0-9._-]`，闸门不再依赖 Unicode 规范化。**
     >
     > 原规格写的是「非 NFC 路径 fail-closed」，落地时发现**它两端做不到同一件事**：TS 有
     > `String.normalize("NFC")`，而 **Dart 无内建 Unicode NFC**。若 Dart 略过该检查，两端卫生
     > 闸门就对同一份 bundle 给出**不同判定**，且 Dart 方向是 fail-open——这正是 §3 风险 5
     > （跨语言实现漂移）本身，而不是它的防御。给 Dart 引入第三方 NFC 实现只是把漂移面换个地方，
     > 还给 🔒 加载器加了一个新依赖。
     >
     > 故改从源头消灭：**该字符集内不存在非 NFC 形式**，也不存在同形异码（homoglyph）与 RTL
     > override 之类的显示欺骗，于是「要不要做 NFC」在两端都不再是问题。TS 侧保留 NFC 断言作
     > 零成本的第二道锁（字符集规则若将来放宽，它能立刻兜住）。
     >
     > **代价**：adapter 内文件名不得使用非 ASCII。现有全部 adapter 均已满足，且这是**内部打包
     > 路径**，与任何面向用户的展示文本无关。跨语言 golden 用例 `non_ascii_path` 钉住两端同判。
  4. **blob 集合精确相等。** descriptor 的 `sha256` 集合与 blob 表的键集合必须**一一对应**：多一个 = 夹带通道，少一个 = 拒。每个 blob 解码后长度须**精确等于** `size`（先用 `size` 界定再解码，防 endless-data，同 TUF 携带 length 的理由），且哈希须命中 descriptor。**这是本方案唯一新增的、可以搞砸的地方**，必须双端 golden 钉死四个负例：多余 blob / 缺失 blob / 哈希不符 / 重复 path。
  5. **全量文件承诺。** 签发时若 adapter 目录内存在未进 envelope 的文件（`BUNDLE_INCLUDE` 扩展名白名单之外者），**拒签**——取代原先的静默剔除。否则 digest 只承诺「这些文件」，不承诺「只有这些文件」，目录侧路径（DEV-Sideload、[`adr_033`](./adr_033_production_sideload.md) 本地导入）即存在夹带面。
  6. **`bundleFormat` 严格相等**（非前缀匹配）。两端均已落实。

  **验签层与加载策略的分界（2026-09-09 落地时明确，🔒 待 owner 签收）**：验签回答的是
  **「这串字节是谁、以什么档位签的」**——档位是它*产出*的已验证事实，不是它的准入条件。
  **「只加载 official」是信任策略，属于加载器**（§2.6 / 红线 #4），在验签之上一层。

  故两端**刻意不对称**，且这个不对称本身要被钉住：TS `openBundle` 服务于台账提取、签发侧自验
  等**非加载**场景，返回 `ok + tier`；Dart `openBundle`（它**是**加载器入口）在最后一步拒绝
  非 official。把 official-only 塞进验签层会逼台账这类调用方接受一个会拒 sideload 的 API，
  而那里恰恰需要「已验签的 sideload 事实」。跨语言 golden 用例
  `valid_signature_sideload_tier` 带 `loaderMustRefuse` 标记，同时钉住这两件事。

- **不为性能放宽任何验签步骤（2026-09-09 owner 决策，实测支撑）。** 「每次加载都重新验签」（ADR-018 §2.6）是否有性能代价可换——**实测结论是没有可换的东西**。用 5 份真实 official bootstrap bundle 走真实代码路径（`unpackBundle` → `envelopeDigest` → `verifyBundleSignature`），200 次均值（桌面 x86）：

  | bundle | gz | unpack | **digest** | verify（含内部 digest） | 单次合计 |
  |---|---|---|---|---|---|
  | 最大 `56056b26` | 6791 B | 398 µs | **226 µs** | 2555 µs | **≈3.2 ms** |
  | 最小 `8a6ab755` | 758 B | 37 µs | **15 µs** | 1853 µs | ≈1.9 ms |

  - **可放宽的不值钱**：哈希重算在最大的真实 bundle 上是 **226 µs，占单次加载 7%**；全部放掉换来的是丢失内容寻址保证。
  - **值钱的不能放宽**：成本主体是 **Ed25519 验签 ≈1.8 ms，且与体积无关**（758 B 的包也要 1.85 ms）——而它正是红线 #4 的执行点（official 独占、档位裁定、公钥 pin）。
  - **digest 在缓存命中路径上算两次**（`bundle_cache.read` 一次、`verify.dart` 步 3 一次）是**故意的纵深防御**，成本 226 µs，**保留**。
  - digest v2 落地后此项再降一个数量级（改为哈希 ~1 KB 的清单，不再是全部文件字节）——2026-09-09 已落地，真实 `school-xidian@0.4.1` 的 envelopeBytes 为 **319 B**（v1 下要哈希的是 32 KB 文件字节）。
  - 若将来真成瓶颈，正确动作是换平台加速 Ed25519（现为纯 Dart `cryptography` 2.9.0），**不是放宽验证**；但那要在验签路径引入新原生依赖（红线 #9 + 🔒 审查），为 ~2 ms 不划算。**当前此线无待办。**

- **签名域分隔：同一把密钥下的多个签名协议必须显式隔离（2026-09-01 新增）。** official 密钥同时签 bundle 载荷 / catalog / revocation 三类对象，v2 之前三者只靠「JSON 形状恰好互不满足对方 schema」**偶然隔开**（现状记录见归档 §4），第四个签名对象出现时随时可能撞上。故统一规定：

  ```
  签名输入 = contextTag ‖ 0x00 ‖ 被签字节
  ```

  `contextTag` 为固定 ASCII 串，三者各异：`elecon.bundle-payload/2`、`elecon.catalog/1`、`elecon.revocation/1`。**传输对象不变**（前缀只加在签/验的输入上），故「验字节 → 再 parse」的取向不受影响。新增任何签名对象必须同时分配一个新的 `contextTag`，不得复用。

- **为何 bundle 保留「载荷套一层」而 catalog/revocation 直签字节**：catalog / revocation 的全部语义都在其 JSON 里，直签字节即可；bundle 的 `tier`（裁定档位）**不在** envelope 内——它是签名流程注入的、不可由被签内容自述的判定（§2.2），故必须有一个承载它的载荷。该载荷 = `{ context, adapterId, adapterVersion, tier, digest }`，其中 `digest` 是 envelope 字节的哈希。这一层间接是有理由的，保留。

- **构建期规范化（保留规则，但不再是 digest 的一部分）**：以下规则**仍然有效**，位置从「哈希前静默改写」改为 `buildEnvelope` 的**构建期检查——不符即拒绝签发**：
  1. **文件排列顺序**：`files` 按相对路径的 UTF-8 code point 字典序排列（`manifest.json` < `src/index.js` < …）。顺序现已进签名范围，故它是 envelope 的一部分，而非哈希算法的一个步骤。
  2. **换行符**：一律 **LF**（`\n`）；出现 CR/CRLF 即拒绝签发。
  3. **编码**：一律 **UTF-8 NFC**；未规范化即拒绝签发。
  4. **无 trailing newline 增删**：以磁盘字节为准。
  5. **二进制资产（图片等）**：不做文本规范化，按原始字节入 **blob 表**（按内容 SHA-256 寻址）。
     > **digest v2 起 envelope 内不再有 `encoding` 字段**——descriptor 只有 `path`/`size`/`sha256`，
     > 文件字节整体移出 envelope。这不是笔误的修正而是设计目的之一：**编码彻底离开信任边界**
     > （Node 与 Dart 的 base64 解码器行为实测不同——Node 对 `Qh==`/`QQ`/含空白宽松接受，Dart 全抛；
     > 只要 envelope 里还有 `encoding`，这个差异就在验签路径上）。

  **为何改判**：改为「拒绝而非改写」后签名与磁盘字节一一对应，Dart 加载器不引入任何 Unicode 规范化实现（详见归档 §3.1）。

- **可复现性的负担下降（本次修订的附带收益）**：原规格要求 TS 与 Dart **两套实现**共同维持同一哈希算法不变量（排序、拼接、编码解码）；新规格只要求**签端一处**产出确定性字节（显式序列化器：固定键序、无多余空白，由 golden 钉死），验端只做「哈希收到的串」。[`adr_018`](./adr_018_adapter_distribution.md) §3 风险 (e)「所见非所签」的唯一防线——离线签名机上重算 digest 与审查沙箱产物比对——完好保留，且更易做对。

- **迁移：不设代码兼容层，但需要一次重签仪式（2026-09-01 核实修正）。** `release/adapter-release-ledger.json` 的 `records` 为空——但那是 **P0-15 台账尚未建立**，**不等于未签发过**。实际已存在 **7 份 official 签名 bundle**（`dist-full/` `dist-xidian/` `dist-helloworld/` 下的 `bundles/*.json.gz`，其中 5 份随包在 `client/assets/bootstrap/`），全部由 `elecon-official-ncc-1` 真机签发，另有已签名 catalog（sequence 3）与 revocation list。这些产物**无外部持有者**（随 app 二进制分发 + 仓内 dist），故仍**不设双读、不新增 host version gate**（旧端遇 `/2` 由 `verify.dart` 既有 `bundleFormat` 严格相等自动拒载）；但 `/2` 落地必须伴随一次**离线 YubiKey 重签仪式**：5 个 adapter + catalog + revocation 重新签发、`npm run bootstrap:sync` 重新派生随包资产。**该仪式应与 [`adr_026`](./adr_026_response_masker.md) §2.7 已预定的「手工补齐 `masker.json` 并重新签发」合并为同一次**，并借机把 P0-15 台账首批记录一次补齐。

  > **状态（2026-09-09）**：`/2` 的**代码**两端已落地并全绿；**重签仪式尚未执行**，故仓内 7 份 v1 产物当前一律拒载——这是「无代码兼容层」的预期行为，不是缺陷。重签时须 bump `school-helloworld` 版本号（该版本曾被两次不同字节签发，见 [`2026_08_review_remediation.md`](../planning/2026_08_review_remediation.md) §2.3）。仪式完成前 `client/test/school_manifest_test.dart` 的 bootstrap 用例处于**条件跳过**（检出 v1 即 skip，重签为 v2 后自动恢复）。
  > **状态（2026-09-11）**：重签仪式已执行——5 份 adapter（fudan/thu/xjt/helloworld 0.1.1、xidian 0.4.1）+ catalog（sequence 8）+ revocation（sequence 2）由 `elecon-official-ncc-1` 真机签发，`bootstrap:sync` 已重派生，台账首批 5 条 `complete`。masker 未随此次仪式（RM0 未移除），第二次仪式随 ADR-026 §2.7.1 断代到 `/3`。记录见整改清单 §2.7。

- **现网产物暴露面：潜伏但尚未武装（2026-09-01 核实；缺陷已于 2026-09-09 随 digest v2 修复，本段保留为当时的风险论证）。** 攻击可行的**充要条件**是「在 `manifest.json` 的字典序**同一侧**存在 ≥2 个文件，且其中至少一个不按固定路径查找」——因为按固定路径查找的文件（`manifest.json`、`runtime.entry`、`masker.json`）各自钉死一个排序位次，位次全被钉死时重命名无自由度。当前 7 份已签发 bundle 的 `files` **全部恰为 `[index.js, manifest.json]`**，两个槽位都必需 → **不可利用**；补入 `masker.json` 后为 `[index.js, manifest.json, masker.json]`，三者分居三个固定位次 → **仍不可利用**。暴露面在**第一份携带运行时资产的 bundle**（[`adr_018`](./adr_018_adapter_distribution.md) §2.9「+ 运行时资产,若有」）出现时打开。故本项**不需要紧急吊销**，但必须在任何 adapter 开始携带资产之前落地。

  > **已落地（2026-09-09）**：digest v2 两端实现完成，路径已进签名范围，**该暴露面自此关闭**——上述「充要条件」只对 v1 成立。回归门 `tools/src/bundle/path-binding.smoke.ts`（26/26）常驻 `smoke:all`，其 A 组即此攻击的可执行复现。**本段不删**：它记录的是「为什么当时判定不需要紧急吊销」，那个判断本身仍须可追溯。

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
- **校验**：核心在加载 official adapter **之前**验签，针对当前 **active** 的 pin 公钥；验不过 → 拒绝（fail-closed）。**传输底座不在这条链路上**——它编译期编入二进制、没有加载期决策，完整性由平台应用签名承担（ADR-003 §2.3，2026-09-09）。`tools/src/signer`（经离线 YubiKey 后端）产出签名，核心消费。**验签逻辑与 pin 公钥体系不因签名后端更换而变**——KMS→YubiKey 只改「私钥怎么出签」，不改「核心怎么验签」。

### 2.4 吊销（Revocation）

- **吊销清单**：签名的 revocation list（按 `adapterId` + 版本范围 / 具体 bundle 哈希），经**公网哑服务**分发（公开数据、零凭证，契合红线 #2）。
- **核心行为**：拉取 + 验签吊销清单，拒绝加载被吊销的 bundle；支持**最低版本下限**强制升级有漏洞的 adapter；支持密钥泄露时的总开关（kill-switch）。
- **时效与离线**：吊销清单自带新鲜度/TTL；拉取失败时回退到**上一份已验签的清单**（绝不把"拉不到"当成"全部放行"）。
  **TTL 是陈旧度信号，不是加载门（2026-09-12 明确）**：客户端对 catalog / revocation 一律采用最高 sequence 的已验签份，过 TTL 只进遥测、不拒载——一份陈旧的已签清单仍含全部历史吊销，属 fail-closed 倾向；急性吊销依赖在线拉取 + sequence 单调 + kill-switch，与 TTL 无关。TTL 唯一的硬约束落在发版门（P3-08 G2）：不把已过期的基线清单打进新装包。据此 revocation 的 TTL 取长（180 天量级）即可，短 TTL 只会逼迫仪式节奏而不增加安全。
- **首次启动 / 全新安装的 bootstrap（消解 fail-closed 的两难）。** "回退到上一份已验签清单"在全新安装、**尚无 last-good** 时无依据，会陷入「fail-open 不安全 / fail-closed 离线即不可用」两难。对策：**App bundle 内预置一份初始的已签名吊销清单**（随发版更新），作为 last-good 的初值——新装即有一份可信基线，离线也能 fail-closed 而不瘫。这与 [`adr_010`](./adr_010_ios_appstore.md) §2.2「bundle 预置基线 adapter」同源：让 App 在零网络下即自包含可用。预置清单只是**下限**，联网后按 TTL 拉取更新。

### 2.5 本地导入与 DEV-Sideload 闸门（红线 #4；ADR-033 修订，已接受待落地）

- **渠道不等于信任档**：DEPLOY 本地文件若通过 official 验签与治理门，仍按 official 运行；`devSideload` 只在 DEV profile 可铸造。
- **当前运行基线**：ADR-033 已接受但尚未落地，故 ADR-024 的 DEPLOY 零本地导入实现与 gate 目前仍原样生效——这是实现进度，不是 ADR 状态。
- **落地后的 DEPLOY**：设置内保留低频本地导入，只接受 official 签名；每次新增/更新必须在线刷新并验证 catalog/revocation，网络失败、陈旧、回滚、吊销或身份不符均拒绝。入口低可达性不替代安全门禁。
- dev 传输底座同样**仅 debug build**存在（编译期门控；transport 的签名/加载门已于 2026-09-09 作废，见 [`adr_003`](./adr_003_transport.md) §2.3）。
- **DEV-Sideload 全部允许**：无签名 adapter 可用 declarative / imperative，并调试登录、收割、ssoMint、dataflow、action 等当前 DEV 宿主已编入能力；可触发开发者测试凭证注入，但凭证值仍不离核心。DEV 可以是优化的 `--release` build，必须使用独立 applicationId、启动警告且不可分发。**风险以多重警告兜底，不以 declarative 阉割兜底**：
  - **DEV 启动即提示**：进入 DEV profile 时持久提示「当前为开发版；未审查 adapter 可驱动核心使用开发者测试凭证、读取脱敏后的私密响应并在声明白名单内发请求」。不得表述成 adapter 能看到凭证值；红线 #1 在 DEV 仍成立。
  - **侧载 imperative adapter 时全占用确认**：加载含 `requestGraph: imperative` 的无签名 adapter 前，弹**全占用模态框**逐条列明风险（该 adapter 未经签名/审查、将获得凭证注入能力、可读取私密响应），用户须显式确认方可继续。
  - 上述警告 UI 与"允许注入"分支均挂在编译期 `kSideloadEnabled` 下，**DEPLOY 不存在**。
- **DEPLOY 维持信任约束不变**：任何未签名 / 非 official adapter 无运行路径。ADR-033 只增加 official bundle 的本地字节来源，不增加生产低信任档。

### 2.6 纵深防御：静态（tools）+ 运行时（core）

| 闸门 | 位置 | 职责 |
|---|---|---|
| 静态 | `tools/` 校验器（CI） | 校验 requestGraph 结构、白名单、凭证引用、capability registry 与能力专属规则。**`C3_sideload_must_declarative` 是与 §2.1.1 决策相悖的遗留断言**（决策：sideload 可加载任意 adapter），目前仍会开火——移除由 ADR-033 §5 编排，须与 DEPLOY official-only 负例同批，不得只删断言。 |
| 运行时 | 可信核心 | DEPLOY 无论 catalog / 本地来源都只接受 official 验签 + 身份绑定 + 吊销 + stdlib 门全过的 bundle；本地新增/更新额外要求在线新鲜治理材料。DEV-Sideload 可铸造未签名开发 context，但该路径不进入 DEPLOY。 |

**DEPLOY 中 `ctx.fetch` 的形态（2026-06-13 调整；触发条件 ADR-022 改为 imperative requestGraph）**：`ctx.fetch` 在 imperative 入口对所有档**一律存在**——目的是让错误送入的非 official context 拿到清晰的「权限不足」错误，而不是晦涩的 `TypeError`。但这不削弱 capability-based 保证：
- **档位由宿主据验签结果裁定**（非 adapter 自报），校验**在宿主边界 fail-closed**。
- DEPLOY 非 official 的 `ctx.fetch` 调用在拿到任何网络/凭证能力前即被拒；本地导入也不能绕过。
- DEV-Sideload 是显式全能力例外，可驱动核心使用开发者测试凭证；该放行由编译期 profile 隔离，不能据此推导 DEPLOY 放行。

**适用范围（ADR-024 / ADR-033）**：DEPLOY 的权威边界是 official grant，不是字节来源；非 official 在加载与宿主边界均被拒。DEV-Sideload 是正交全能力例外，未签名 context 与开发凭证放行由编译期 profile 隔离。优化等级与信任 profile 正交，不能以 `debug/release` 代称二者。

---

## 3. 已知约束与风险（Consequences）

1. **最高敏感路径（红线 #1/#4）。** 实现与测试**不得 AI 独自闭环**；需安全检查清单 + 人工审阅（git.md §3、testing.md）。
2. **密钥管理是单点，已多重缓解。** 私钥泄露 = 信任根失守。缓解：① 私钥托管 **离线硬件 token（YubiKey）、永不导出、PIN+触碰本地签名**（§2.3，2026-07-15 修订）——失陷面从"偷走密钥"降为"物理窃取 token 且破 PIN"，且签名不在任何网络/CI 上、无远程出签面；② **多公钥预埋 + 分批启用**（§2.3）应对丢失（晋升备用）与泄漏（吊销收窄）——每把 YubiKey 各持独立密钥、全部公钥预埋，丢一把即晋升 dormant；③ kill-switch（§2.4）。残余风险：(a) 放大信任方向（晋升 dormant 公钥）**一律随发版**（不做热推启用声明），恢复速度受应用商店审核节奏制约；(b) 无云端逐次签名审计，改用 git 台账（§2.3）+ 人工纪律；(c) 单人持 token 是发布瓶颈/SPOF——用 ≥2 把 token（各自密钥、均预埋）+ 物理异地备份缓解；**(d) 首把 official 令牌 `elecon-official-ncc-1` 兼作维护者日常 GPG 签名令牌、日常随身携带**（2026-07-16 owner 决策），物理失窃暴露面高于专用离线令牌——缓解：窃得令牌者仍须破 PIN（3 次重试即锁）且**每签必须物理触碰**（`touch-policy=ALWAYS`），失陷后走吊销 + 晋升 dormant。**若日后引入专用离线令牌，应优先将其设为 active、把本把降为 dormant**；**(e)「所见非所签」**——§2.3 的「离线」指**不在任何自动化 / 云上**，签名本就发生在维护者**本地机**（非气隙），故被攻陷的本机可在触碰的瞬间替换待签载荷。`touch-policy=ALWAYS` 只保证「每一签都有人在场」，**不保证「签的是你以为的那个东西」**。这是本方案的**结构性残余风险**（KMS 方案同样有，只是换成"被攻陷的 CI 提交错载荷"）。缓解只能靠 ceremony 纪律：签前在**即将触碰的这台机器上**重算 digest 并与 CI 产出的 unsigned bundle 比对（§4 工作流），不可只看 CI 的输出。急性事件靠 kill-switch + 吊销兜。后续若需更快恢复可另起 ADR。
3. **community 档已砍（§2.1）。** 信任模型简化为 **official + sideload** 两档，维护者不再为"可分发性"背书，去掉了审查瓶颈。代价：社区贡献者要么自行 debug 侧载、要么经审查被收编为 official，**没有"已签名可分发但仍由社区维护"的中间态**。`community` 枚举值已于 2026-06-14 修订**从 `contract/manifest.schema.json` 与 ADR-001 §5 移除**（契约改动，红线 #6；向后兼容性见 §2.1——此前无生效验证路径，移除不放松约束）。`tools/scanner` 的 PII/危险 API 静态筛查仍对"收编 official 前的审查"有用，保留。
4. **离线/陈旧吊销的可用性权衡。** fail-closed 与"拉不到清单时仍可用上次良好状态"之间的策略已在 §2.4 定调（last-good 回退 + bundle 预置初始清单解全新安装的两难），避免吊销机制本身成为 DoS 面。残余权衡：预置清单的新鲜度受发版节奏限制，急性吊销仍依赖联网拉取 + kill-switch。
5. **签名规范化（canonicalization）已钉死规格（§2.3），残余风险在跨平台实现一致性。** 规则已固定（字典序 / LF / UTF-8 NFC / 二进制资产不变；**digest v2 起改为哈希 envelope 序列化字节，双层 SHA-256 拼接已被取代**），**v2 起验端不再排序**——顺序已随 `files` 数组进入被签字节，验端只哈希收到的那一串，跨端排序一致性这一整类风险随之消失（签发侧仍按字典序构建，由 golden 钉死）。NFC 自 v2 起由「哈希前静默改写」改为**构建期拒签**；且 2026-09-09 落地时进一步把**路径段字符集收紧为 `[A-Za-z0-9._-]`**，故加载器侧不需要、也不得实现 Unicode 规范化（Dart 无内建 NFC，两端若各行其是即是本条所指的漂移）。
6. **与契约的边界。** `trustTier` 的 `community` 枚举清理已于 2026-06-14 修订**随本 ADR 一并落地**（§2.1，红线 #6，向后兼容）——这是经人工 owner 批准的契约改动，非"顺手改"。若日后需在 manifest 增签名/背书相关字段，仍另起独立 ADR。
7. **`ctx.fetch`"存在但档位校验"需下游一致性更新（§2.6）。** 此取向改了运行时 ctx 形态——[`adr_009`](./adr_009_fetch_credential.md) §2 决策 7、[`adr_008`](./adr_008_client_runtime.md) 客户端运行时及 declarative ctx 实现须一致。DEPLOY 非 official 仍 fail-closed；DEV-Sideload 全能力例外由编译期 profile 隔离。

---

## 4. 落地清单（拆成可审查的小 PR）

> 本 ADR 已接受（见头部状态），本节不是「待接受后再做」的预案，而是**已授权的落地清单**；
> 各项的落地与签收状态见 [`README.md`](./README.md) 与 [`2026_08_review_remediation.md`](../planning/2026_08_review_remediation.md)，本文不重复记录。

> 安全敏感项标（人工主导、AI 仅辅助）：

- ~~`tools/src/signer`~~ **✅ 已落地（2026-07-16 真机核验）**：bundle 规范化（§2.3 规格：字典序 / LF / UTF-8 NFC；**digest 已于 2026-09-09 随 digest v2 改为 `SHA-256(envelopeBytes)`，原「双层 SHA-256 拼接」作废**）+ **Ed25519 签名经离线 YubiKey 后端**（`YubiKeySignBackend` → `YubiKeyPkcs11Signer`，PIV/PKCS#11 `CKM_EDDSA`，私钥驻留硬件、不入仓；开发阶段可用 `LocalDevSignBackend` 软密钥）/ 验签 + 吊销清单生成。签名管线细节见 [`adr_018`](./adr_018_adapter_distribution.md)；ceremony 见 [`signing_ceremony.md`](../reference/signing_ceremony.md)。
- **新依赖声明（红线 #9）**：`pkcs11js`（**MIT**）——PKCS#11 2.40 的 Node 绑定，仅供 `tools/src/signer/pkcs11.ts` 在**离线签名机**上驱动 YubiKey；**不进客户端 / 服务端二进制，不随 [`adr_018`](./adr_018_adapter_distribution.md) §2.8 的镜像发布**。定为 **`optionalDependencies`**：它是原生模块（node-gyp），而 CI / 普通开发机既无令牌也未必有构建工具链——惰性 `import` + fail-closed，缺它时 validator / scanner / digest / 验签均不受影响。MIT 与红线 #9 的 GPL 传染性隔离要求无冲突。
  - 实现注意（已在代码内注释钉死）：`pkcs11js` 只实现到 **PKCS#11 2.40**，而 Ed25519 相关机制是 **3.0** 才引入的（`CKM_EDDSA`=0x1057、`CKM_EC_EDWARDS_KEY_PAIR_GEN`=0x1055）——**须自行定义常量**。且该包是 CJS、常量动态赋值到 `module.exports`，ESM `import` 拿不到（全为 `undefined`，症状伪装成参数类型错），须取 `default`。
- **离线硬件签名工作流**（取代原 OIDC→KMS 管线）：CI/审查沙箱只产出 **unsigned bundle + digest**；维护者本地重算 digest 确认一致 → YubiKey PIN+触碰签 → 提交 `signature.json` + 更新发布台账。签名不在任何自动化上。实现注意：须取**裸 64 字节 Ed25519 签名**（PIV/PKCS#11，非 OpenPGP packet 封装）以对齐现有验签——`YubiKeySignBackend` 与 `YubiKeyPkcs11Signer` 两处均有 64B 守卫（纵深防御）。**「本地重算 digest 比对」是 §3 风险 2(e)「所见非所签」的唯一防线，不可省。**
- 可信核心：DEPLOY 加载前验签（active pin）+ 吊销 + 签名裁定档位 + `ctx.fetch` 档位校验（非 official → 结构化权限错误、永不触达注入）；DEV-Sideload 的显式放行分支单独隔离。客户端与服务端核心共享裁定语义。
- **多公钥预埋 + 分批启用**：active/dormant 公钥集合；晋升（应对丢失）/ 停用（应对泄漏）方向不对称（§2.3）；**晋升与集合增删一律随 App 发版**（不做热推启用声明）。
- `tools/` 校验器：补 requestGraph 与能力专属静态检查。当前保留 `sideload + imperative` C3；ADR-033 已决定退役，落地时须同批补 DEPLOY official-only 负例，不得只删断言。
- 侧载闸门：ADR-033 落地前仍确保全部本地导入入口从 DEPLOY 剔除；落地后改为确保 **devSideload grant、未签名执行与 DEV 凭证放行路径**从 DEPLOY 剔除，同时 DEPLOY 本地入口只汇入 official verifier + 在线治理门。DEV 形态为独立应用身份 + 启动持久警告 + 全占用确认。🔒 安全敏感，人工主导。
- 吊销分发：公网哑服务托管签名吊销清单；核心拉取/验签/回退策略。
- 测试：验签正/反例、谎报档位提权反例、**DEPLOY** `ctx.fetch` 非 official 拒绝、**DEV-Sideload** 未签名 imperative 放行但凭证值不可见、公钥晋升/停用、吊销与规范化；安全敏感测试人工编写或实质审阅。
- 契约：`trustTier` 枚举 `community` 清理**已于 2026-06-14 修订落地**（`contract/manifest.schema.json` + ADR-001 §5，红线 #6，向后兼容见 §2.1）。manifest 签名字段如需新增另起独立 ADR。
