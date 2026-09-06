# ADR-018：adapter 仓库分离 · 分级审计 · 打包与签名途径 · 解释器版本同步

- **状态**：**已接受（Accepted） 2026-07-15 经人工评审批准。** 触碰红线 #4（仅官方签名加载）/#5（adapter 越薄）/#6（契约承重墙）/#2（公网零凭证）/#1（凭证）。**决策已定，可据以实现;但实现层仍受 [AGENTS.md](../../AGENTS.md) §1 约束**——签名/加载/分发/凭证等价物检测属安全敏感承重路径，**AI 不得独自闭环**（实现与测试须人工主导 + 安全清单 + ≥1 人工审），此约束不因 ADR 已接受而解除。
- **日期**：2026-07-15（**修订 2026-07-16**（**经人工 owner 评审批准**，真机接线后回填）：§2.3 硬件签名由「待接线」改为**已接线并经真机核验**（`YubiKeyPkcs11Signer`，`CKM_EDDSA`，首把密钥 `elecon-official-ncc-1`）+ 补**密钥形态**（片上生成 / 槽位 9c / PIN+触碰 ALWAYS / **不放 X.509 证书** / 固件 ≥5.7.0）+ §4 勾掉 signer 项并声明新依赖 `pkcs11js`（MIT）。**四信任域、流水线、catalog/bundle 格式、加载器设计均未变**;ADR-002 §2.3/§3/§4 同步修订。）
- **依赖**：
  - [`adr_000_abstract.md`](./adr_000_abstract.md)（§2.1 公网哑服务无状态、§2.2 可信核心、§2.4 推 adapter 不发版的边界、§3.3 凭证边界、§3.4 传输底座）
  - [`adr_001_contract.md`](./adr_001_contract.md)（manifest / capability registry 契约、schemaVersion）
  - [`adr_002_trust_model.md`](./adr_002_trust_model.md)（**本文落地其 §2.3 签名管线（含 2026-07-15 KMS→YubiKey 修订）与 §2.4 清单分发**；两档信任、验签 fail-closed、多公钥预埋）
  - [`adr_005_runtime.md`](./adr_005_runtime.md)（QuickJS 双端同引擎、零漂移）
  - [`adr_007_public_deploy.md`](./adr_007_public_deploy.md)（公网哑服务部署形态，延后）
  - [`adr_010_ios_appstore.md`](./adr_010_ios_appstore.md)（DPLA §3.3.2「非代码市场」「热推只在既有能力集内」「bundle 预置基线」）
- **被依赖**：（待实现 PR / 后续 ADR）
- **适用范围**：adapter 的**源码托管、社区贡献、分级审计、打包、签名、分发、客户端加载**，以及 adapter 所依赖的**解释器运行时（QuickJS 引擎 + `elecon:html` stdlib）版本同步与安全**。**不含**：签名密码学机制本身（ADR-002 §2.3）、fetch 运行时凭证注入（ADR-009）、UI。

---

## 1. 背景（Context）

至今 adapter 与核心同仓（`adapters/`），贡献即改主仓。要让社区**低门槛提交** adapter、同时让客户端**只加载官方签名包**，需要把「谁写」与「谁签、谁分发」拆开，并回答四个此前未定的问题：

1. **仓库怎么分？** 社区提交在哪、官方源真相在哪、签名与分发在哪，各自信任边界如何？
2. **审计怎么分级？**（已确认前提：不同风险面审查强度不同。）
3. **打包/签名走什么途径？**（ADR-002 §2.3 已于 2026-07-15 把签名从 AWS KMS 改为离线 YubiKey。）
4. **解释器版本怎么同步？** adapter 依赖宿主提供的 QuickJS 引擎 + `elecon:html` stdlib；包与客户端各自独立发版后，版本偏斜会破坏「双端不漂移」与确定性。

红线约束（承重墙）：#1 凭证永不离核心；#2 公网哑服务零凭证/无状态；#4 DEPLOY 无论 catalog / 本地来源都仅运行 official；#5 DEV-Sideload 全能力但不可分发、凭证值仍不离核心；#6 契约改动先 ADR 且向后兼容。DEPLOY 本地 official 导入与 C3 退役见 ADR-033（已接受，尚未落地）。

---

## 2. 决策（Decision）

### 2.1 四个信任域（仓库分离 = 信任边界分离）

「服务器能不能跑 adapter」不是红线的提法；红线管的是**哪个信任域、碰不碰凭证**。把角色拆成四个**必须分开部署/分权**的盒子：

| 信任域 | 职责 | 跑 adapter？ | 持凭证？ | 隔离手段 | 红线 |
|---|---|---|---|---|---|
| **A. 社区暂存仓库**（public，如 `elecon-adapters`） | 贡献者 PR;仅预检（validator/scanner/digest），产出**未签名 sideload 素材** | 否（仅静态校验） | 否 | 公开仓库 + CI 无签名能力 | #5/#8 |
| **B. 审查/打包沙箱**（服务端，构建期） | 二次审查:容器内跑 adapter 做性能/行为验证 + 打包 unsigned bundle + 算 digest | **是** | **仅测试账号**（复用 broker 注入，adapter 仍看不到凭证值） | **容器隔离 + 无生产密钥**（dev 侧载-imperative 的服务端类比，ADR-002 §2.5） | #1（broker 不泄值）/#5 |
| **C. 签名**（离线，维护者） | 对 digest 做 YubiKey PIN+触碰签名 → `signature.json` | 否 | 否（私钥在硬件） | **离线气隙 + 硬件 token**，私钥连服务器都不上 | #4（ADR-002 §2.3） |
| **D. 公网分发端点**（`server/src/public` / CDN） | 客户端拉 signed bundle + catalog + revocation | 否 | **否（根本不放）** | **无状态、零凭证**，可退化为静态 CDN | #2 |

> **DEPLOY 加载边界**：A 产出的未签名素材用于 DEV-Sideload 全能力调试；进入 DEPLOY 前必须经过 B 审查与 C official 签名。ADR-033 增加用户本地文件来源（待落地），但它只绕过 D 的字节下载，不绕过 official 验签，并须在线取得 D 发布的最新 catalog/revocation 治理材料。

> **正交提醒**：运行时的 `server/src/campus`（校内授权中继，带真实凭证取私密数据，红线 #3）与本文的**分发**无关——分发管"把签名包送到客户端"，中继管"运行时取数"。本文不改中继。

**关键不变量**：B（跑未签名 adapter 做审查）与 D（客户端拉包的公网端点）**必须是不同信任域**——不因 B 要跑 adapter 就让面向客户端的 D 持有凭证/状态；C（签名私钥）**不上任何服务器**，即便 A/B/D 全被投毒也偷不到签名权。

### 2.2 分级审计与流水线

```
社区暂存仓库 A
  → CI:语法审查 + 性能审查（纯静态 / 沙箱，无凭证）          ← 自动
  → 人工「简单」安全审查                                     ← 门 1（分级：见下）
  → 合入「官方 main」（源真相，尚未签名）
  ─────────────────────────────────────────────
  → 同步到审查沙箱 B:容器跑 adapter 二次审查（测试账号）      ← 门 2
  → 打包（unsigned bundle + digest）
  → 离线 C:YubiKey 签 official + 更新发布台账                ← 签名门 = 门 2 的产物 + 人工触碰
  → 推到公网端点 D（零凭证静态产物）
  → 客户端验签 → 查吊销 → 加载
```

**审查强度分级**（呼应「已确认审查分级前提」）：

| adapter 形态 | 门 1（进 main） | 门 2 + 签名（成 official） |
|---|---|---|
| **declarative**（无网络、无凭证、纯解析；`requestGraph: declarative`） | 快车道:审查面仅 index.js 映射逻辑（stdlib 是宿主代码，不在包内，见 §2.4） | 沙箱跑夹具比对 golden + 签名 |
| **imperative**（凭证注入、白名单出网；`requestGraph: imperative`） | 慢车道:重度人工安审（凭证作用域、allow、无副作用），红线 #1 承重 | 沙箱用**测试账号**端到端跑 + 逐项安全清单 + 签名 |

**两条必守不变量**（否则 ADR-010「非代码市场」立论崩）：

1. **签名门 = 门 2 的人工二次审查。** "打包"里的签名必须由持 YubiKey 的维护者**在场触碰**执行,**不得**在审查沙箱 B 上放签名私钥自动签——否则投毒 B = 偷到签名权。
2. **合入 main ≠ 已签名。** main 是源真相；签名是之后一个受门控的 release 动作（ADR-002 §2.3 release owner 显式签）。

### 2.3 打包与签名途径（离线 YubiKey，落地 ADR-002 §2.3）

- **打包产物 = 规范化 bundle + `signature.json`（detached）**。bundle 规范化 digest 规则已由 ADR-002 §2.3 钉死（字典序 / LF / UTF-8 NFC / 双层 SHA-256），`tools/src/signer` 已实现确定性 digest。
- **签名 = 离线手动一步**：B 产出 unsigned bundle + digest → 维护者在离线机上**本地重算 digest 确认与 B 一致**（digest 确定性，可独立复现）→ YubiKey **PIN + 物理触碰**对 `{digest, tier=official, adapterId, adapterVersion}` payload 签 Ed25519 → 落 `signature.json`。
- **实现接缝（✅ 2026-07-16 已接线并真机核验）**：`tools/src/signer` 既有 `SignBackend` 抽象（`sign(payload)→base64`）→ `YubiKeySignBackend` → **`HardwareEd25519Signer` 接缝** → **`YubiKeyPkcs11Signer`**（`tools/src/signer/pkcs11.ts`，PIV/PKCS#11 `CKM_EDDSA`，取**裸 64 字节** Ed25519 以对齐 `verifyAdapter`）。`KmsSignBackend` 已删除。**验签侧完全不动。** 多一层 `HardwareEd25519Signer` 接缝的理由：把「硬件怎么出签」与「签名管线」解耦——换令牌品牌 / 换 PKCS#11 模块只动 `pkcs11.ts`，且管线可用 fake provider 测试而不碰硬件。
- **密钥形态（落地 ADR-002 §2.3 的证书决策）**：**片上生成**（`CKM_EC_EDWARDS_KEY_PAIR_GEN`，私钥从不存在于硬件之外）、PIV 槽位 **9c**（Digital Signature 语义）、`pin-policy=ALWAYS` + `touch-policy=ALWAYS`（**生成时固化不可改，漏设会静默降级，须复核**）、**不放 X.509 证书**（实测 libykcs11 走 PIV metadata 枚举，无证书亦可出签；信任锚只有裸 32B Ed25519 公钥）。**固件须 ≥ 5.7.0**（PIV Ed25519 下限）。完整 ceremony 见 [`signing_ceremony.md`](../reference/signing_ceremony.md)。
- **密钥备份/丢失**：≥2 把 YubiKey，**各持独立密钥**，全部公钥预埋（1 active + 余 dormant，复用 ADR-002 §2.3 多公钥机制）。丢一把 → 晋升 dormant（随发版）。物理异地备份。
- **审计台账**：无云端逐次日志，改用 **git 跟踪的发布台账**（`adapters-release-ledger` 或仓内文件），每次签名追加一行 `adapterId / version / digest / date / keyId / 签署人`,提交进仓。
- **过渡（✅ 硬 deadline 已达成）**：硬件签已就位（首把密钥 `elecon-official-ncc-1`，2026-07-16）。dev/staging 仍可用 `LocalDevSignBackend`（软密钥，产物不分发终端）；**面向用户的 release 一律走硬件签**（ADR-002 §2.3）。

### 2.4 解释器版本同步与安全（stdlib 走 B-host + append-only）

adapter 依赖两层宿主运行时:**QuickJS 引擎**（ADR-005，双端同引擎）+ **`elecon:html` stdlib**（`adapters/_stdlib/html.bundle.js`，宿主注入，**不随 adapter 分发**）。包与客户端各自发版后，二者版本偏斜会破坏确定性与「双端不漂移」。

**决策:stdlib 由宿主提供（B-host），不打进 adapter 包。** 理由（决定性的是前两条）：

1. **审查面收缩**:社区 declarative 包里**只有 index.js 映射逻辑**,htmlparser2/css-select 是**宿主已审计代码**,不进社区供应链。反案（打进包）会放大审查面 + 攻击面（包内可夹带被改的 stdlib，须逐字节比对才发现）。
2. **App Store 立场更硬**:真正的"代码能力"（HTML 解析）在 **app 二进制里、随发版审核**;网上拉的只是薄映射，离 2.5.2「下载代码改变功能」更远。
3. stdlib 安全修复**一次发版全体生效**，不用重签所有 adapter。
4. 包体积小。

**版本偏斜消化（最简模型，不用复杂 range）**：

| 机制 | 做法 |
|---|---|
| adapter 声明 | manifest 新增 `runtime.stdlibMin`（如 `"1.2.0"`），声明"至少需要 stdlib 此版本"。此字段在 manifest → **已被签名 digest 覆盖** |
| 双端锁步 | 每次 release，client 与 server 打**同一个 stdlib 版本**（从同一源构建），保住双端不漂移 |
| 加载器强制 | 两端加载器:本端 stdlib 版本 `< stdlibMin` → **fail-closed 拒载**（提示需升级 app） |
| stdlib 纪律 | stdlib 独立 semver + **append-only**:老 API 永不删改、只增 → 高版本恒能跑低版本 adapter，前向兼容自动成立 |
| QuickJS 引擎 | 引擎版本同理随发版双端锁步;引擎升级视为发版级变更（影响面测试 + golden 复跑），adapter 不声明引擎版本（假设宿主引擎恒兼容既有 ES 子集） |

`runtime.stdlibMin` 是**契约新增**（红线 #6，向后兼容:纯新增可选字段，缺省=不设下限）。

**残余风险**:append-only 是**硬承诺**——一旦破坏（改了老 API 行为），已签名的老 adapter 会在新 stdlib 上静默漂移。须以 stdlib golden 测试 + CI 钉死"老 API 行为不变"。

### 2.5 catalog 作为契约新增（签名分发清单）

客户端需要一份索引才知道有哪些 adapter、版本、digest、下载地址 = **catalog**。它被**可信核心验签消费、fail-closed**，与 manifest schema 同等承重,故**作为契约新增**:

- 新增 `contract/catalog.schema.json`（catalog 条目:`adapterId / adapterVersion / digest / url / stdlibMin / capabilities[]`）+ validator + golden。红线 #6，由本 ADR 引入。
- **catalog 本身须签名**（**2026-07-15 确认:与 adapter bundle 同一 Ed25519 / YubiKey pin 公钥集**）+ 带 `sequence` **防回滚** + TTL + last-good 回退——与 revocation list **共用同一「signed distribution manifest」模式**（复用 `tools/src/signer/revocation.ts` 的 `sequence`/`pickNewer`/TTL 机器）。未签名/可回滚的 catalog 可被 CDN 中间人替换成"指向旧的有漏洞版本"。
- **硬约束:catalog 不得引入新 capability id。** validator 对着 `contract/capability/registry.json` 强制:catalog 里每个 capability 必须已在 registry（既有能力集内）。新 capability/新卡片类型**只能随 app 发版改 registry**（ADR-010 §2.1，守住 §3.3.2(a) 立论）。
- **签名对象 = catalog 的原始 JSON 字节（byte-exact，2026-07-15 定）。** 线上格式:
  `SignedCatalog = { catalogJson（被签的原始 JSON 文本）, signature, keyId, algorithm }`——**签 / 传 / 验 / 解析用同一份字节**;验签通过后才 `parse`，且验签函数**返回已解析的 catalog**（调用方拿不到未验签数据，fail-closed）。
  - **为何不重新规范化序列化**:手写字段列表的 `serialize()` 会**静默漂移**——schema/类型新增字段而序列化没跟上，该字段即落在**签名范围之外**（CDN 可随意改它而签名仍有效）;这种漂移还会**跨语言**（Dart 加载器须再实现一份同样的规范化）。字节精确从根上消除两者:**新增字段自动进签名范围**，Dart 侧只需"验字节 → 再 parse"，零规范化、零漂移。与 §2.9 bundle 的取向同源（envelope digest 哈希的是**文件字节**，故也无键序问题）。
  - 同理适用于 revocation list（同一「signed distribution manifest」模式）。

> **身份绑定（与 §2.9 联动，2026-07-15 定）**:bundle 签名载荷里的 `adapterId/adapterVersion` 与 digest 是**两个维度**——digest 只绑定内容。故 ① **签端**身份一律取自 envelope 内 `manifest.json`（不接受调用方传入）;② **验端**须核对签名身份 == bundle 内 manifest 身份，不符即 fail-closed。否则「digest 覆盖内容 A、载荷却写身份 B」的签名仍可验过，而运行时用的是 bundle 内 manifest（决定 allow/credentials/scope）→ **身份混淆**。这落实 ADR-002 §2.2「与 manifest 自报不符则拒绝加载」。

### 2.6 客户端加载器设计

- **fail-closed 顺序（不可改）**:取 catalog → **验 catalog 签名 + sequence 不回滚** → 下载 bundle → **重算 digest 比对** → **Ed25519 验签（active pin 公钥）** → **查 revocation**（TTL / last-good / kill-switch / minVersion）→ **校验 `stdlibMin` ≤ 本端 stdlib** → 由签名裁定档位 → 交 QuickJS。任一步失败即拒、不加载。
- **内容寻址缓存**:以 `digest` 为缓存 key——天然抗篡改、去重、支持回滚校验。**不得"验一次缓存永久信任"**:每次加载以内容寻址保证加载的就是验过的字节。
- **原子更新**:下载须先验签再落地，杜绝加载半个 bundle。
- **bundle 预置基线（ADR-010 硬要求）**:app 内打包一组**已签名 baseline adapter + 初始 catalog + 初始 revocation list**,首启/离线可用;远程拉取仅用于"更新/新增数据源"。审核员在提交 build 上即可走通核心功能。
- **平台节奏（2026-07-15 定）**:**两端都先建好基础设施**（bundle 格式 / catalog / 加载器 / 端点 D）。**远程拉取 Android 先行**;**iOS 基础设施同样建好,但远程拉取功能与 2.5.2(a) 自检押后**再开（与 ADR-016 平台门禁同思路）——差异只在"何时开拉取开关",不在"是否建"。

### 2.7 与 App Store 合规的联动（继承 ADR-010）

- 「非代码市场」当前依赖 DEPLOY 无本地入口 + official 分发。ADR-033 若接受，论证改为：设置内只导入项目 official 签名包、无任意 URL/catalog/第三方 key，并强制在线吊销治理；须由 ADR-010 人工合规复核后才能落地 iOS。
- 热推只换"数据源映射"、不引入功能:由 §2.5 catalog 不得引入新 capability + §2.4 stdlib/引擎能力在 app 内 共同强制。

### 2.8 单个 adapter 项目结构与 adapters 仓库组织

**单个 adapter 项目**（沿用现 `adapters/school-xidian`、`school-xjt`,越薄越好）:

```
school-<id>/
  manifest.json      契约声明(capability / network.allow / mode / trustTier / runtime.stdlibMin / credentials / login)
  index.js           QuickJS ES module,导出 capabilities;仅归一化逻辑,import 仅 `elecon:html`
  fixtures/          脱敏抓包样本(golden 输入/输出);真实数据 gitignore,scanner 强扫 PII(红线 #8)
  README.md          该校信息 / 已知坑
  [FLOW.md]          可选:多步 fetch 流程说明(如 xjt)
```

- **`signature.json` 不在项目源码里**——它是**签名阶段（C 域）生成的 detached 产物**,不进社区仓库,由离线签名产出后随 bundle 分发。
- **stdlib 不在项目里**(B-host,§2.4):`index.js` 只 `import 'elecon:html'`,不打包解析器。
- **fixtures / README / FLOW.md 是开发期产物,不进交付 bundle**(signer `BUNDLE_EXCLUDE` 已排除 fixtures,§2.9)。

**两仓库、两组织、两可见性（2026-07-15 定）**:

| 仓库 | 组织 / 可见性 | 持有（源真相） | 说明 |
|---|---|---|---|
| **私有核心仓 `elecon`** | 主组织 / **private** | **contract**（红线 #6 承重）、**`_stdlib`**（受信任宿主代码）、**`tools/validator`+`scanner`**（闸门逻辑）、client/server 核心、签名、ADR | 一切**受治理 / 受信任**之物;社区改不动自己的闸门 |
| **公开 adapters 仓 `elecon-adapters`（A 域）** | **另一组织 / public** | `adapters/school-*`、`_template`、`CONTRIBUTING`、CI 配置 | 纯社区**创作面**（薄 adapter）;`main` 分支 = 官方 adapter 源真相 |

**所有权归属（2026-07-15 收回 elecon）**:contract / stdlib / validator / scanner 的**源真相全部在私有核心仓**,不落公开仓——因为 stdlib 最终打进受信任 app 二进制、contract 是红线 #6 承重、validator 是闸门逻辑,若住在社区 PR 会落地的公开仓,一个恶意 PR 即可投毒受信任组件或削弱自身闸门。

**核心 → A 的只读发布（取代原「私有子模块 pin」——私有主仓 + 公开 A 下子模块会断掉外部贡献者）**:核心把 pin 版本的 **contract + stdlib（bundle + `elecon:html` 类型面）+ validator/scanner** 单向发布给 A,供贡献者本地按固定契约创作/校验:

- **MVP:CI 镜像 / vendored 快照**（低基建,单向同步 job,零 npm 发布）。
- **后续:npm 包**（`@elecon/contract` / `@elecon/stdlib-html` / `@elecon/adapter-kit`,更干净的 `npm i`,待发布流水线就位再上）。

```
elecon-adapters/（public,另一组织）
  adapters/
    _template/                   脚手架(imperative / declarative 两模板)
    school-<id>/ …               各校 adapter(见上)
  vendor/  (或 node_modules 经 npm)  【只读:核心发布的 pin 版 contract + stdlib + validator/scanner】
  .github/workflows/             CI:validate + scan + digest 预检(§2.10);无任何签名能力
  CONTRIBUTING.md                贡献指南 + 分级审查说明(§2.2)
```

- **消费方向单向**:契约/stdlib/闸门由私有核心定,A 只读消费;**签名向的构建拉取**（核心 → 从 A 的 main 拉源做审查/打包/离线签,§2.1 B/C 域）也是单向,私有产物不外泄。这也是 ADR-002 §2.3「开源走独立仓库」纵深防御的一层。
- PR 通过 CI + 人工门 1 → 合入 A 的 **main = 官方 main**(此时**仍未签名**,§2.2)。

### 2.9 交付给用户的包形态（signed bundle）

发放给用户的**不是**整个项目目录,而是**签名 bundle**:

- **内容 = digest 覆盖的运行时文件 + detached 签名**:`manifest.json` + `index.js`(+ 运行时资产,若有)+ `signature.json`。**fixtures / README / FLOW.md / node_modules 一律剔除**(signer `BUNDLE_EXCLUDE`)。
- **内容寻址**:catalog 以 `digest`(ADR-002 §2.3 **digest v2**)标识每个 bundle 版本;客户端拿到字节 → 重算 digest → 验签 → 交 QuickJS(§2.6)。
- **容器封装（2026-07-15 定，同日修订 tar→gzip-JSON；2026-09-01 修订 digest 与上线形态）**:**签名对象 = 确定性 JSON envelope**——`{ bundleFormat, files: [{ path, encoding, content }...] }`,文件为 §2.3 BUNDLE_INCLUDE 集、按路径字典序、内容 LF/NFC（构建期检查，不符即拒签）。
  - **为何弃 tar（原方案）**:① envelope JSON 本身已是多文件容器,tar 的多文件打包冗余;② 手写 tar 需再移植解析器到 🔒 Dart 加载器(验签前的自研二进制解析,edge case 累积);③ gzip 用两端**内建 codec**（node:zlib ↔ Dart `GZipCodec`）——🔒 加载器零自研归档解析;④ gzip 自带压缩省客户端流量。gzip 头非确定性**无碍**:它在签名之外。
  - **为何也不签压缩包字节（2026-09-01 记）**:曾考虑"整包压缩后签压缩字节"（APK v2 式单段连续字节）。方向对、落点错——gzip 输出不确定（压缩级别、header 的 OS 字节/mtime、zlib 版本），签压缩字节会**废掉 §3 风险 (e)「所见非所签」的唯一防线**（离线机重算 digest 与审查沙箱产物比对），也使 P0-15 台账无法从 source commit 复算 digest。故取**未压缩的 envelope 字节**：同样是单段连续字节，但可从 git checkout 复现。若"包"指 tar/zip，则等于把自研归档解析器塞回 🔒 加载器，正是当初弃 tar 的理由。

  - 硬约束:① envelope 只含 digest 覆盖文件 + detached 签名;② digest 可从 source commit 复现;③ 验签 fail-closed 且**先于解析**;④ 解包后**以内容寻址校验**（重算 digest 比对签名声明）,不信任传输层元数据;⑤ 验签后**必过路径卫生闸门**方可使用。

- **体积上限（红线 #5 越薄的硬防线）**:validator 对 bundle（BUNDLE_INCLUDE 文件总字节）设上限,超限**加载前拒**（`C11`）。"脚本非常大"由此在提交期挡掉,而非靠容器兜底。
- **预置基线同格式**:app 内预置的 baseline adapter 用同一 bundle 格式(§2.6),保证在线更新与离线基线一致可验。
- **stdlib 不在 bundle 内**(B-host):运行时由宿主注入,版本经 `stdlibMin` 协商(§2.4)。

#### 2.9.1 digest v2 与上线形态（2026-09-01 修订）

**缺陷**（详见 ADR-002 §2.3「被取代的规格」）:原 digest 只哈希**按路径排序后的内容**,路径自身不进哈希 → **保序重命名**不改 digest,而加载器按路径取入口与 `masker.json` → official 签名可背书受审时无害的资产文件被执行。验收红用例 `tools/src/bundle/path-binding.redcase.ts`（现 2/14，A2/B1/C1–C9/D1 红）。

**修订后的规格**——envelope 从「容器」降为「清单」，文件字节改由按内容哈希寻址的 blob 表承载:

```jsonc
// envelope = 签名对象（小、可读、可人眼审完）
{
  "bundleFormat": "elecon-bundle/2",
  "adapterId": "school-xidian",
  "adapterVersion": "0.3.1",
  "files": [
    { "path": "index.js",      "size": 4211, "sha256": "9f2c…" },
    { "path": "manifest.json", "size":  812, "sha256": "3ab0…" },
    { "path": "masker.json",   "size":  147, "sha256": "c751…" }
  ]
}

digest = SHA-256( envelopeBytes )                       // envelopeBytes = UTF-8(JSON(envelope))

// on-wire（.json.gz）
gzip(JSON({
  "envelopeB64": "<base64(envelopeBytes)>",             // 不透明字节串,不是嵌套对象
  "signature":   { adapterId, adapterVersion, tier, digest, signature, keyId, algorithm },
  "blobs":       { "<sha256>": "<base64(raw bytes)>" }  // **按内容哈希寻址,不按路径**
}))
```

`blobs` 按哈希而非路径寻址,故仍是纯 JSON、🔒 加载器零自研归档解析（弃 tar 的理由完好）,且**编码彻底离开信任边界**:解码器宽严无关,产出字节必须命中 descriptor 的 `sha256`。gzip 仍在签名之外、仅作传输压缩。

**Ed25519 签名输入带域分隔**（ADR-002 §2.3）:`"elecon.bundle-payload/2" ‖ 0x00 ‖ serializePayload(...)`;catalog 与 revocation 同法加 `elecon.catalog/1` / `elecon.revocation/1`。传输对象不变,前缀只加在签/验输入上。

**验证顺序（不可改，fail-closed）**:

| # | 步骤 | 说明 |
|---|---|---|
| 1 | 压缩体上限 → 有界 gunzip | `kMaxBundleGzBytes` / `kMaxBundlePayloadBytes` 不变（压缩炸弹护栏） |
| 2 | 解析**外层信封**（仅 `envelopeB64`/`signature`/`blobs` 三字段） | 验签前唯一允许的解析;严格类型,多余字段拒 |
| 3 | base64 解码得 `envelopeBytes`（受字节上限约束） | 非规范 base64 拒 |
| 4 | 算法只认 `ed25519`;`keyId` → **预埋 active** 信任锚（命不中即拒） | 不按签名文件自述选算法 |
| 5 | `SHA-256(envelopeBytes)` 比对 `signature.digest` | 内容寻址 |
| 6 | Ed25519 验签（带 `contextTag` 前缀的载荷） | **到此为止未 parse 过 envelope** |
| 7 | **才** `JSON.parse(envelopeBytes)`;`bundleFormat` 严格相等 | 两端对称:Dart `verify.dart` 已有,TS `verifyBundleSignature` 须补 |
| 8 | **路径卫生闸门** | 重复 / 绝对（含 `C:` 盘符）/ `.`·`..` 段 / 反斜杠 / 空 / 尾随分隔符 / NUL / 非 NFC → 整体拒载 |
| 9 | **blob 集合精确相等** | descriptor 的 `sha256` 集合 ↔ blob 键集合一一对应;多一个（夹带）或少一个均拒 |
| 10 | 逐文件:先按 `size` 界定 → 解码 → 长度**精确等于** `size` → `SHA-256` 命中 descriptor | 防 endless-data;编码差异在此被吸收 |
| 11 | **身份三方一致**:签名载荷 ↔ envelope 顶层 ↔ `manifest.json` 内容 | 任一不符即拒（ADR-002 §2.2 加强版） |
| 12 | stdlibMin 门 → 吊销 → 交 QuickJS | 与现行 §2.6 顺序一致 |

**为何第 8 步不能省**:签名只证明发布者确实想要这些路径,不证明路径安全。当前 bundle 内容不按路径落盘（`bundle_cache.dart` 以 digest 为 key）,故多数项是纵深防御;但**重复路径是活口子**——Dart `List.sort` 不保证稳定、TS `Array.sort` 保证。且 `masker.json` 唯一性（ADR-026 §2.7 C3）与 ADR-033 本地导入都直接依赖这一步。

**为何第 9 步是新的风险点**:blob 集合精确相等是本方案**唯一新增的、可以搞砸的不变量**。少一个 blob 会被第 10 步抓到,但**多一个 blob 不会**——它必须由第 9 步显式拒绝,否则就是夹带通道。双端 golden 必须钉死四个负例:多余 blob / 缺失 blob / 哈希不符 / 重复 path。

**签发侧新增硬约束**:`buildEnvelope` 对目录做**全量文件承诺**——目录内存在未进 envelope 的文件即**拒签**,取代 `BUNDLE_INCLUDE` 的静默剔除（`fixtures/`、`README`、`node_modules`、`.git` 等仍按 `BUNDLE_EXCLUDE` 显式排除,排除名单本身进版本控制）。LF/NFC 由静默改写改为**不符即拒签**。

**为何也不签压缩包字节**:见 §2.9「为何也不签压缩包字节」。

**落地清单**（🔒 每项均触红线 #4，须人工复核，AI 不得独自闭环）:

1. `tools/src/bundle/envelope.ts`:envelope 改 descriptor（`path`/`size`/`sha256` + 顶层身份）;显式确定性序列化器（固定键序、无多余空白）;`digest = SHA-256(envelopeBytes)`;`BUNDLE_FORMAT` → `elecon-bundle/2`。
2. `tools/src/signer/index.ts`:`serializePayload` 加 `contextTag` 前缀;`computeBundleDigest(dir)` 走 `buildEnvelope(dir)` 同一条 digest;`collectBundleFiles` 增全量文件承诺;`canonicalizeContent` → `assertCanonical`（拒绝而非改写）。
3. `tools/src/catalog/sign.ts` / `tools/src/signer/revocation.ts`:签/验输入加各自 `contextTag` 前缀（传输对象不变）。
4. `tools/src/bundle/package.ts`:上线形态改 `{envelopeB64, signature, blobs}`;实现验签先于解析;补 `bundleFormat` 检查、卫生闸门、blob 集合精确相等、逐文件 size/hash 校验、三方身份一致。
5. `client/lib/core/loader/bundle.dart` / `verify.dart`:同上（Dart 侧只需「哈希收到的串」+ 逐 blob 校验,删除排序与逐文件拼接哈希）。
6. `contract/golden/bundle/loader.json`:改为 `{ envelopeBytes(hex), blobs, expectedDigest, signature, publicKeyRawHex }` 形态,两端同向量;新增卫生闸门与 blob 集合四负例向量。
7. `tools/src/bundle/path-binding.redcase.ts`:补 descriptor 形态的负例（见文件末「待实现后可表达」清单）;全绿后改名 `path-binding.smoke.ts` 纳入 `smoke:all`。
8. **迁移 = 无代码兼容层 + 一次重签仪式**（2026-09-01 核实修正）:ledger 为空是 P0-15 台账未建立,**不等于未签发**——实存 7 份 `elecon-official-ncc-1` 签发的 official bundle（5 份随包在 `client/assets/bootstrap/`）+ 已签 catalog（sequence 3）+ revocation。无外部持有者,故 `/1` 路径整体删除、不设双读、不新增 host version gate（旧端由既有 `bundleFormat` 相等判断自动拒载）;但须一次离线 YubiKey 重签（5 adapter + catalog + revocation，随后 `bootstrap:sync` 重派生），**与 ADR-026 §2.7 已预定的「补齐 `masker.json` 后重签」合并为同一次**，并一次补齐 P0-15 台账首批记录。
9. **暴露面核实**:攻击充要条件 = 「`manifest.json` 字典序同一侧存在 ≥2 个文件且至少一个不按固定路径查找」。现存 7 份 bundle 的 `files` 全为 `[index.js, manifest.json]`,补 `masker.json` 后为三个固定位次 → **均不可利用**;暴露面在第一份**携带运行时资产**的 bundle 出现时打开。故不需紧急吊销,但须在 adapter 开始携带资产前落地。
10. **未纳入本批**:manifest `trustTier` 的去留。它无运行时消费者,但是 validator 三道签发期闸门（C3、`ssoMint` official-only、masker official-only）的输入,且 ADR-033 §5 明文要求 C3 删除须与 DEPLOY official-only 负例同批、不得抢跑。目标形态是把「意图档位」改为**签发流水线显式入参**（与 ADR-002 §2.2 同构）而非留在 manifest,随 ADR-033 落地一并处理。

### 2.10 语法 / 静态检查的方式（展开 §2.2 门 1 CI,复用既有 `tools/`）

门 1 的"语法审查"是**纯静态、无凭证、可自动**的一层,复用 `tools/validator` + `tools/scanner` + 编译检查:

| # | 检查 | 手段 |
|---|---|---|
| 1 | **manifest schema 合法** | ajv(`tools/validator`)：结构 + `trustTier` + per-cap `requestGraph` + capability id ∈ registry + `stdlibMin` + credentials scope 等。当前另拒 `sideload+imperative`（C3）；ADR-033 已决定退役 C3 使 DEV 素材可完整预检（待落地），DEPLOY 由 official grant 门禁承担。 |
| 2 | **JS 可编译 + import 白名单** | index.js 作为 ES module 解析(esbuild/acorn 或 QuickJS compile 空跑);**import 仅允许 `elecon:html`**,禁止任意外部/相对 import |
| 3 | **declarative 档源码静态检查**(ADR-002 §2.6 闸门) | AST 扫描:declarative capability 不得出现网络/凭证/副作用 API(`fetch`/XHR/`eval`/`Function`/`globalThis` 逃逸等) |
| 4 | **fixtures 脱敏扫描**(红线 #1/#8) | `tools/scanner`:真实学生数据(PII)**一律拒** + **凭证等价物模式扫描**(ticket / JSESSIONID / Set-Cookie / openid 等,接 Track B B8 token-pattern);**强制通过方可合并** |
| 5 | **digest 预检** | 算规范化 digest(不签,只算),作后续离线签名的比对基线,防"审的和签的不是同一字节" |
| 6 | **golden 一致(轻量)** | 对 fixtures 跑 adapter,产出须等 golden;declarative 可在 CI 轻量比对,imperative 端到端留沙箱 B(§2.2) |

> **边界**:语法/静态检查是"能否解析 / 是否越权"的**静态门**,**不等于**人工安全审查(门 1 的人工部分)或行为审查(沙箱 B)。三者是纵深防御的不同层,缺一不可。
>
> **🔒 MVP 不可推迟项(红线 #1)**:fixtures 一进**公开**仓库,凭证等价物即时外泄风险生效。故上表第 4 项的**「拒绝凭证等价物 + PII」门必须随 MVP 就位**——录制/脱敏**工具**可推迟(§2.11 Phase 3),但这道**门**不可推迟(§2.11)。现有 xidian(公开通知无凭证)/ xjt(反爬 `client_id` 非学生凭证)夹具已安全,可先搬;此门须在任何**带凭证** adapter 落公开仓**之前**生效。

### 2.11 分期落地（MVP 优先,逐步填空白）

分离先立起来,签名远程分发那套重机器逐步填。三期:

| 期 | 目标 | 含 | 消费方式 |
|---|---|---|---|
| **MVP（先做）** | 公开 A 成为 adapter 创作/校验之家 | A 脚手架 + 搬 xidian/xjt + `_template` + CONTRIBUTING;核心→A **镜像** pin 的 contract/stdlib/validator(§2.8);CI §2.10 静态子集(schema + 编译 + import 白名单 + **PII/凭证等价物扫描** + digest) | **核心构建期从 A 拉 adapter**(§2.11.1 按需拉取,跑现有 sandbox smoke)——**先不上签名远程分发** |
| **Phase 2** | 签名远程分发 | YubiKey 签名(§2.3)+ bundle 格式(§2.9)+ catalog(§2.5)+ 客户端加载器(§2.6)+ 公网端点 D | 客户端验签→查吊销→远程加载 + 预置基线 |
| **Phase 3** | 开发者测试层 + 采纳自动化 | 测试 harness CLI(复用零漂移沙箱)+ 夹具/golden 约定 + **imperative 夹具录制/脱敏工具** + 沙箱 B 自动化 + npm 包发布 | — |

- **MVP 本质**:"分离"立即成立(公开创作面 + 静态 CI + 核心构建期消费),不阻塞于重机器。
- **不可推迟的安全底线随 MVP 走**(§2.10 注):凭证等价物/PII 扫描门。
- Phase 2/3 各自可再拆小 PR(见 §4);顺序上 **契约先行**(`stdlibMin` + catalog schema)。

### 2.11.1 核心侧消费机制：按需拉取，取代 git 子模块（2026-07-26 增补，经人工 owner 批准）

MVP 落地时，核心构建期消费公开仓 A 的 `adapters/school-*` 一度实现为 **git 子模块**（`vendor/elecon-adapters`，pin 固定 SHA）。实践暴露两处不优雅，改为**按需浅拉取（on-demand shallow fetch）**：

- **自我镜像回灌**：A 仓同时含 `adapters/school-*`（A 的源真相）**与** `vendor/`（§2.8 core→A 单向镜像进来的 contract/stdlib 快照）。子模块是**整仓**单位，核心把 A 整个拉进 `vendor/elecon-adapters/` 时，`.../vendor/contract/` 成了核心自身 `contract/` 的**陈旧回灌副本**——核心工作区里出现两份 contract，纯死重量 + 误编辑风险。这是一个**内容环**（core 的受治理产物出去、又随子模块回来），虽非构建期死锁（镜像单向 + 子模块 pin 手动 bump，无自激），但不必要。
- **粒度过粗**：核心只需 A 的 `adapters/`，子模块却强制拖入 `vendor/`、`package-lock.json`、A 的 CI 配置等全部内容；git 子模块设计上无法只挂子目录。

**决策**：核心**不再以 git 子模块跟踪 A**，改为在需要 adapter 的 CI job / 本地开发中**按需 `git clone --depth 1` A 到一个 gitignored 路径**，并经既有解析接缝消费——消费侧代码零改动：

- 解析优先级已就位（`server/src/runtime/__testutils__/smoke-utils.ts`、`client/test/utils/test_utils.dart`）：`ELECON_ADAPTERS_REPO`(env) → 并排检出 `../elecon-adapters` → **skip-if-absent**（`ELECON_REQUIRE_ADAPTERS=1` 时缺仓即 fail）。按需拉取只需把 clone 落点导出为 `ELECON_ADAPTERS_REPO`。
- **钉版本从 gitlink 改为显式文本 pin**（`adapters.pin`，记 tag/commit SHA）：比子模块 gitlink SHA 更可读、diff 更清楚，bump = 改一行。
- 从核心 git 图移除子模块指针 + 回灌的自身副本；内容环随之消失（核心只再单向消费 A 的 `adapters/`）。

**未来迁移预留（`elecon-contract-mirror`）**：core→A 的镜像目标（§2.8 line 172 的 A `vendor/`）后续迁往**独立的 `elecon-contract-mirror` 仓 / npm 包**（部分基础设施已预留其位）。届时 A 只放社区 adapter、其 CI 消费独立的 contract mirror，A 里不再有 core 的镜像内容——**内容环从源头彻底断开**，每个仓单向流动。这与 §2.11 Phase 3「npm 包」演进同向（§2.8「后续:npm 包」），是其分发侧的具体落点。

> **不变量不变**：消费方向仍严格单向 core←A（只取 `adapters/`）；镜像方向仍单向 core→A（§2.8/§3.9）；A 永不回写 core 的 contract/stdlib/validator。本次只换**核心侧的取件机制**（子模块 → 按需拉取 + 文本 pin），四信任域、镜像 job、签名分发均不变。

---

## 3. 已知约束与风险（Consequences）

1. **安全敏感承重路径（红线 #1/#2/#4）。** 签名（C）、加载器验签顺序（§2.6）、审查沙箱凭证隔离（B）**不得 AI 独自闭环**;实现与测试须人工主导 + 安全清单 + ≥1 人工审。
2. **采纳规模化瓶颈。** 采纳=人工审查+签名,正是 ADR-000 要减的人力。缓解:declarative 快车道（审查面小，§2.2）+ imperative 慢车道分级;绝大多数社区 adapter 是 declarative。规模再大时的取舍留后续 ADR。
3. **签名单人瓶颈/SPOF。** 离线 YubiKey 把签名系于持 token 的人。缓解:≥2 把 token（各自密钥、均预埋）+ 异地备份（§2.3）;急性事件靠 kill-switch/吊销（ADR-002 §2.4）。无云端审计,靠 git 台账 + 人工纪律。**另见 ADR-002 §3 风险 2 的两条残余风险（2026-07-16 补）**:(d) 首把令牌兼作日常随身 GPG 令牌 → 物理失窃面偏高;(e) **「所见非所签」**——签名在维护者本地机（非气隙），被攻陷的本机可在触碰瞬间替换载荷,`touch=ALWAYS` 挡不住,**唯一防线是签前在该机重算 digest 与 B 产出的 unsigned bundle 比对**（§2.3 第二条已要求，不可省）。
4. **stdlib append-only 是硬承诺。** 破坏即令已签名老 adapter 静默漂移（§2.4）。须 stdlib golden 钉死老 API 行为不变;引擎升级视为发版级变更、复跑 golden。
5. **catalog / 分发端点是攻击面。** catalog 未签名/可回滚 → CDN 中间人可降级到有漏洞版本。已以"catalog 签名 + sequence 防回滚 + last-good"封（§2.5）。公网端点 D 严守零凭证/无状态（红线 #2）。
6. **契约新增（红线 #6）。** 本 ADR 引入 `runtime.stdlibMin`（manifest schema）+ `contract/catalog.schema.json`,均向后兼容（纯新增）。实现须同步 `tools/` validator + 双端 golden。
7. **审查沙箱 B 跑未签名 imperative adapter + 注入。** 是 ADR-002 §2.5 dev-sideload-imperative 的服务端类比,**仅测试账号**;B 不是 release 二进制，故可跑,但须与 D、C 分域,且测试账号绝不用真实学生凭证（红线 #1/#8）。
8. **App Store 依赖 ADR-002/010 落地状态。** 硬件签就位前 iOS release 不得开启任何远程/未签名 adapter 加载路径,否则 §3.3.2(b) 立论不成立（ADR-010 §7）。
9. **跨组织/私有-公开供应链（§2.8）。** 私有核心构建期消费公开仓 A 的社区 adapter——由分级审查 + 签名门兜(§2.2)。核心→A 的**镜像发布 job** 是新面:须单向、只读、pin 版本;绝不反向(A 不得回写 contract/stdlib/validator)。受信任组件(contract/stdlib/闸门)源真相留私有核心(§2.8 所有权),社区 PR 触不到。残余:MVP 镜像为手工/CI 快照,版本漂移靠 pin + 发布纪律,npm 化后收敛(§2.11 Phase 3)。**核心侧消费机制** 2026-07-26 由 git 子模块改为按需拉取(§2.11.1):消除子模块把 A 的镜像 `vendor/` 回灌进核心导致的自身 contract 陈旧副本(内容环),取件仍单向 core←A、只取 `adapters/`;镜像方向与信任域不变。

---

## 4. 落地清单（本 ADR 已接受，拆成可审查的小 PR 落地）

> 🔒 = 安全敏感（人工主导、AI 仅辅助）。

- **契约**（红线 #6，先落）:`contract/manifest.schema.json` 增 `runtime.stdlibMin`（可选）;新增 `contract/catalog.schema.json` + golden;validator 补「catalog capability ⊆ registry」「stdlibMin 语义」校验。
- 🔒 ~~**signer**~~ **✅ 2026-07-16 已落地（真机核验，经人工评审批准）**:`YubiKeySignBackend` → `HardwareEd25519Signer` 接缝 → `YubiKeyPkcs11Signer`（PIV/PKCS#11 `CKM_EDDSA`，裸 64B Ed25519）;`KmsSignBackend` 已删;catalog 签名/验签复用 revocation 的 `sequence`/`pickNewer`/TTL。首把密钥 `elecon-official-ncc-1`（槽位 9c / 片上生成 / PIN+触碰 ALWAYS / 无证书）。新依赖 `pkcs11js`（MIT，`optionalDependencies`，仅离线签名机，见 ADR-002 §4）。ceremony:[`signing_ceremony.md`](../reference/signing_ceremony.md)。
- 🔒 **审查沙箱 B**:容器化 adapter 运行 + 测试账号 broker 注入 + 性能/行为审查;与 D/C 分域部署。
- 🔒 **客户端加载器**:§2.6 fail-closed 顺序 + 内容寻址缓存 + 原子更新 + `stdlibMin` 校验 + 预置基线 bootstrap。双端（Dart client / 若需 TS）共享裁定逻辑。
- 🔒 **公网端点 D**:`server/src/public` 分发 signed bundle + catalog + revocation（静态、零凭证、TTL）。
- **stdlib 纪律**:stdlib 独立 semver + append-only CI 门（golden 钉老 API 行为）;client/server stdlib+引擎版本锁步构建。
- **社区仓库 A（另一组织 / public，MVP 优先，§2.11）**:公开仓脚手架 + **核心→A 镜像发布** pin 版 contract/stdlib/validator（§2.8，取代私有子模块）+ CI（validator/scanner/digest 预检，**无签名能力**）+ 贡献指南 + fixtures **PII/凭证等价物强制扫描**（红线 #1/#8，MVP 不可推迟）+ 搬 xidian/xjt。
- **静态检查扩展**（§2.10）:validator 补 index.js **可编译 + import 白名单（仅 `elecon:html`）** + **declarative 档 AST 越权扫描**（无网络/凭证/副作用 API，ADR-002 §2.6 闸门）。
- **bundle 容器格式**（§2.9）:定义确定性 on-wire 封装 + 「只含 digest 覆盖文件、剔除 fixtures/docs、可复现 §2.3 规范化 digest」校验;预置基线同格式。
- **发布台账**:git 跟踪的签名台账格式 + 流程文档。
- **测试**:catalog 验签/防回滚正反例、加载器 fail-closed 各步、stdlibMin 拒载、内容寻址缓存不被绕过、预置基线离线可用;🔒 安全敏感测试人工编写或实质审阅。
- **文档**:更新 `adapters/README.md`（分离后的贡献路径）、ADR-007（分发端点形态）联动。
