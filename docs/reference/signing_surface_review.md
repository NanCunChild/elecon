# 签名面与元数据复盘（2026-09-01）

> **状态**：owner 复核后的记录性文档 · **非 ADR**。决策权威是
> [`adr_002`](../adr/adr_002_trust_model.md) §2.2–§2.4 与 [`adr_018`](../adr/adr_018_adapter_distribution.md) §2.5/§2.9；
> 当前整改与阻塞状态权威是 [`2026_08_review_remediation.md`](../planning/2026_08_review_remediation.md)。
> 本文只把「谁签了什么字节、元数据落在哪、谁裁定」摊平成一张可对照的表，并记录复盘发现的五个问题。
> 🔒 全文涉及红线 #4 承重路径；任何据此的改动须人工 + 安全清单复核，AI 不得独自闭环。

本文写于 P0-01（digest v2）**修订已定、实现未落地**的时点。凡标 `【v2 后】` 的行描述的是修订后的
目标形态，不是当前代码。

---

## 1. 三类被签对象

| 对象 | **被签的字节** | 落点 | 消费者 |
|---|---|---|---|
| **bundle** | `serializePayload({adapterId, adapterVersion, tier, digest})` —— **不是** envelope 字节 | 目录侧 `signature.json`（被 `BUNDLE_EXCLUDE` 排除，不进 digest）；线上与 envelope 并列在 gz-JSON 里 | `client/lib/core/loader/verify.dart` |
| **catalog** | `catalogJson` **原始文本字节** | `dist-*/catalog.json.gz`、`client/assets/bootstrap/catalog.json` | `catalog.dart` |
| **revocation** | `listJson` **原始文本字节** | 同上 `revocation.json` | `revocation.dart` |

三者共用同一把离线 YubiKey 私钥（`elecon-official-ncc-1`，PIV 9c，PIN + 触碰 ALWAYS）。
信任锚是 `client/lib/core/loader/trust_anchors.dart` 里编译进二进制的**裸 32B Ed25519 公钥**，
不放 X.509；可启用集合只能随发版变更（ADR-002 §2.3）。

**为何 bundle 多一层载荷、catalog/revocation 直签字节**：catalog / revocation 的全部语义都在其
JSON 里，直签字节即可；bundle 的 `tier`（裁定档位）**不在** envelope 内——它是签名流程注入的、
不可由被签内容自述的判定（ADR-002 §2.2），必须有个东西承载它。这层间接有理由，保留。

---

## 2. 元数据在 adapter 里的位置

| 元数据 | 所在文件 | 进 digest | 权威用途 | 裁定处 |
|---|---|---|---|---|
| `adapterId` / `adapterVersion` | `manifest.json` | ✓ | **身份权威源**；与签名载荷核对 【v2 后】再与 envelope 顶层构成三方一致 | `verify.dart`（ADR-002 §2.2） |
| `trustTier` | `manifest.json` | ✓ | **无运行时用途**（是 claim）；但**是 validator 三道签发期闸门的输入**，见 §3 发现 E | `tools/src/validator/` |
| `runtime.entry` | `manifest.json` | ✓ | 选执行哪个文件 —— **P0-01 的攻击面** | `adapter_launcher.dart` |
| `runtime.stdlibMin` | `manifest.json` | ✓ | stdlib 门的**权威值**（catalog 同名字段只是预下载提示） | `stdlib_gate.dart` |
| `network.allow` | `manifest.json` | ✓ | broker 出网范围 | broker |
| `credentials` | `manifest.json` | ✓ | 注入 scope 与方式（**只有 ref，无值**，红线 #1） | credential store |
| `capabilities` | `manifest.json` | ✓ | 能力声明 | validator K1 |
| `login` | `manifest.json` | ✓ | WebView 登录起点与导航闭锁 | ADR-015 |
| masker 规则 | `masker.json` | ✓（mandatory，**未落地**，受 P0-01 阻塞） | 响应凭证收割策略 | ADR-026 |
| `digest` / `tier` / `keyId` / `algorithm` | `signature.json` | ✗ detached | 内容寻址 + 档位 + 选锚 | `verify.dart` |
| stdlib `html.bundle.js` | **不在 bundle 内** | ✗ | 宿主注入，版本经 `stdlibMin` 协商 | B-host |
| `fixtures/` / `README` / `FLOW.md` | 目录内**被剔除** | ✗ | 开发期产物 | — |

---

## 3. 复盘发现

### 发现 A —— 三个签名协议签的字节形态不一致

catalog / revocation 签**原始字节**（ADR-018 §2.5 明确论证过「不重新规范化序列化」），
bundle 却签一个**包含 digest 的四字段载荷**。digest v2 收敛了一半（digest 变成对连续字节的哈希），
剩下的一层间接由 §1 末尾的理由保留。**处理：无需改动，但理由已写进 ADR-002 §2.3。**

### 发现 B —— 同一把密钥下三个签名协议没有显式域分隔 🔴

三者目前只靠「JSON 形状恰好互不满足对方 schema」偶然隔开：`serializePayload` 的输出缺
`catalogVersion/sequence`，过不了 catalog 校验，反之亦然。这是**偶然的隔离，不是设计出来的**；
第四个签名对象出现时（传输底座二进制、policy pack、bootstrap 清单）随时可能撞上。

**处理：已定入 ADR-002 §2.3** —— 签名输入统一为 `contextTag ‖ 0x00 ‖ 被签字节`，
`contextTag` ∈ {`elecon.bundle-payload/2`, `elecon.catalog/1`, `elecon.revocation/1`}；
传输对象不变，前缀只加在签/验输入上，故「验字节 → 再 parse」不受影响。新增签名对象必须分配新 tag。

### 发现 C —— `keyId` / `algorithm` 在签名之外是安全的，但论证要写下来

篡改 `algorithm` → 不等于 `ed25519` 即拒；篡改 `keyId` → `activeAnchorByKeyId` 换一把公钥去验，
必然验不过；指向 dormant 公钥 → 返回 `null` → 拒。方向都是收窄。**唯一要保持的前提**是
「按 keyId 选锚 → 用该锚验签」这个顺序不能倒成「验过了再看 keyId 是否被吊销」。
**处理：无需改动，前提已写进 ADR-018 §2.9.1 验证顺序表第 4 步。**

### 发现 D —— catalog 与 manifest 四个字段重名，是长期二源风险 🟡

`adapterVersion` / `digest` / `stdlibMin` / `capabilities` 在 catalog entry 与 manifest 里各有一份。
ADR-018 已定「catalog 的只是预下载提示，不作数」，代码也确实以 manifest 为准
（`readEnvelopeStdlibMin` 的注释写得很清楚）。**但没有机械闸门强制二者一致**——catalog 可以宣称
`stdlibMin: 1.0.0` 而 bundle 内写 `2.0.0`，结果是下载完才拒。

**处理（未落地，建议）**：签发期加一致性校验（catalog 签发时逐条比对 bundle 内 manifest）；
运行时保持「以 manifest 为准」不变。不改契约，属 validator/签发工具增强。

### 发现 E —— `trustTier` 不是死字段（更正）

复盘初稿曾判定它「无消费者、可删」。**这是错的。** 它确实无**运行时**消费者（加载器只认签名
裁定的档位），但有**签发期**消费者：

```
tools/src/validator/index.ts:254          C3_sideload_must_declarative
tools/src/validator/index.ts:502          ssoMint mint 能力仅 official
tools/src/validator/response-masker.ts:146  masker 规则仅 official
```

即它是「敏感能力仅 official」这组静态闸门的输入 —— 一个**签发期意图声明**，不是运行时 claim。
且 [`adr_033`](../adr/adr_033_production_sideload.md) §5 明文要求：不删除 `trustTier: sideload` 枚举，
C3 删除须与 DEPLOY official-only 负例同批、不得抢跑。

**处理：本批不动。** 目标形态是把「意图档位」改为**签发流水线显式入参**（与 ADR-002 §2.2
「档位由签名流程注入，不取自 manifest 自报」同构）而非留在 manifest，随 ADR-033 落地一并处理。

---

## 4. 已签发产物盘点（2026-09-01 核实）

`release/adapter-release-ledger.json` 的 `records` 为空——那是 **P0-15 台账未建立，不等于未签发**：

| adapterId | version | tier | keyId | envelope files |
|---|---|---|---|---|
| school-xidian | 0.3.1 / 0.3.0 | official | elecon-official-ncc-1 | `[index.js, manifest.json]` |
| school-thu | 0.1.0 | official | 同上 | 同上 |
| school-xjt | 0.1.0 | official | 同上 | 同上 |
| school-fudan | 0.1.0 | official | 同上 | 同上 |
| school-helloworld | 0.1.0 | official | 同上 | 同上 |

共 7 份（`dist-full/` `dist-xidian/` `dist-helloworld/`），其中 5 份随包在 `client/assets/bootstrap/`；
另有已签名 catalog（sequence 3）与 revocation。

**P0-01 暴露面：潜伏但尚未武装。** 攻击充要条件 = 「在 `manifest.json` 字典序**同一侧**存在 ≥2 个
文件，且至少一个不按固定路径查找」——按固定路径查找的文件各自钉死一个排序位次，位次全被钉死时
重命名无自由度。上表全部是 `[index.js, manifest.json]`（两个必需槽位）→ **不可利用**；
补入 `masker.json` 后三者分居三个固定位次 → **仍不可利用**。暴露面在**第一份携带运行时资产的
bundle**（ADR-018 §2.9「+ 运行时资产,若有」）出现时打开。**不需紧急吊销，但须在 adapter 开始
携带资产之前落地 digest v2。**

**重签仪式**：digest v2 落地须一次离线 YubiKey 重签（5 adapter + catalog + revocation →
`npm run bootstrap:sync` 重派生随包资产）。**与 ADR-026 §2.7 已预定的「补齐 `masker.json` 后重签」
合并为同一次**，并一次补齐 P0-15 台账首批记录。

---

## 5. 处理状态汇总

| 发现 | 结论 | 去向 |
|---|---|---|
| A 签名字节形态不一致 | 保留，理由入档 | ADR-002 §2.3 |
| B 无显式域分隔 | **修**：统一 `contextTag ‖ 0x00 ‖ bytes` | ADR-002 §2.3、ADR-018 §2.9.1 落地清单 #3 |
| C keyId/algorithm 在签名外 | 安全，前提入档 | ADR-018 §2.9.1 验证顺序第 4 步 |
| D catalog/manifest 二源 | **建议修**：签发期一致性校验 | 未排期，不改契约 |
| E trustTier | 本批不动，随 ADR-033 处理 | ADR-018 §2.9.1 落地清单 #10 |
