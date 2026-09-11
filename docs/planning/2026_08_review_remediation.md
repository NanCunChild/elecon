# 项目审查整改清单与修改路线（2026-08-05）

> 本文来自 2026-08-05 的全仓只读审查，是实施清单，不是 ADR，也不改变任何既有契约或安全决策。
> 涉及 `contract/`、签名、凭证、Broker、传输或信任模型的项目必须按 `docs/rules/feature_workflow.md` 走慢车道，并由人工完成安全复核。
> 状态约定：`[ ]` 未开始，`[x]` 已完成。关闭项目时必须同时满足“完成条件”，不能只以 smoke 通过为准。

## 1. 总体目标

整改顺序固定为：

1. 先阻断凭证泄漏、签名完整性和越界出网风险。
2. 再闭合签名加载、Broker、Masker、Credential Store、schema gate 等承重链。
3. 再修普通正确性问题和重复实现。
4. 再统一 ADR、README、发布输入和 CI 的状态源。
5. 最后恢复新 capability、多校、campus relay 和多平台扩展。

在 P0 和 P1 承重项关闭前，不建议继续扩大 actuator、body credential、material seed 或新学校的生产发布范围。

## 2. P0：安全与发版阻断

P0 整改 owner：**NanCunChild**。2026-08-05 执行分组如下；“跳过”表示必须先完成 ADR 修订或澄清，本轮不得修改实现。

| 执行组 | 项目 | 本轮处理 |
|---|---|---|
| A：既有 ADR 落地 | P0-02、P0-03、P0-04、P0-06、P0-07、P0-08、P0-11、P0-12、P0-13、P0-15 | 实施并提供验证证据；安全项由 NanCunChild 人工签收后关闭 |
| B：分段落地 | P0-10 | 先关闭现有入口绕过和取消后提交；handle、policy matcher、actuator 分别受 P1-08、P1-09、P1-12 前置约束，不虚假关闭 |
| C：ADR 阻塞，跳过 | P0-01、P0-05、P0-09、P0-14 | P0-01 需修订 ADR-002/018；P0-05 需修订 ADR-009；P0-09 需澄清 ADR-026 optional 语义；P0-14 landing 要求同步修订 ADR-002 |

实施顺序：日志与 fixture 止血（P0-11/12）→ 请求配额与 Cookie（P0-03/04）→ UI/硬件档/输出 gate（P0-02/06/07/08）→ firewall 现有入口（P0-10）→ ledger 与 release gate（P0-15/13）。P0-13 的 GitHub Environment 配置和 P0-15 的历史签署事实必须由 NanCunChild 提供或确认，不得由实现者猜测。

### 2.1 执行状态（2026-08-05）

| 状态 | 项目 | 结果 / 剩余门槛 |
|---|---|---|
| owner 已签收 | P0-02、P0-03、P0-04、P0-08、P0-11、P0-12、**P0-05** | 实现与自动化测试已完成；NanCunChild 于 2026-08-06 完成人工复核并授权关闭。**P0-05 的 ADR-009 rev-5 与两端实现已于 2026-09-10 由 owner 复签**，自此不再是签收阻塞项 |
| 待真机签收 | P0-06、P0-07 | iOS 已降级为 S/M 且 H 路径 fail-closed；Android 已用 `KeyInfo` 拒绝 software/unknown；仍需 iOS 升级安装及 Android emulator/TEE/StrongBox 矩阵 |
| 部分落地，保持开放 | P0-10 | TS 已阻止取消后 Commit；Dart 已有 firewall/commit 原语与严格 UTF-8 状态；生产 wiring 仍依赖已验签 policy loader/matcher、执行级 query harvest 事务、P1-08/P1-09/P1-12 |
| owner 已签收（2026-09-11） | **P0-13** | reusable CI、main-only preflight、tag SHA/ancestry、审批 hook 已落地；`release` Environment（required_reviewers + branch_policy）与 `refs/tags/v*` ruleset（creation/update/deletion）经 GitHub API 核实存在（§2.6），owner 2026-09-11 勾选关闭 |
| 已关闭（2026-09-11 重签仪式） | P0-01、P0-15 | **P0-01 实现已落地且人工安全复核已签收（2026-09-11，PR #111）**；P0-15 台账工具已落地、历史人工事实 2026-09-09 裁定「合法留白」（§2.3）。两项随 2026-09-11 digest v2 重签仪式关闭（§2.7：catalog seq 8 / revocation seq 2，台账首批 5 条 complete） |
| ADR / 签收阻塞 | P0-09、P0-14 | P0-09 的 miss 决策与纯引擎已落，mandatory loader/runtime gate 仍受 P0-01/P1-04 与生产装配阻塞；**P0-01 于 2026-09-01 解除 ADR 阻塞**——ADR-002 §2.3 / ADR-018 §2.9.1 已就地修订（digest v2 = 对 envelope 字节整体哈希），缺陷已由 `path-binding.redcase.ts` 复现为可执行验收门（现 2/14 红），**owner 已于 2026-09-09 签收该修订，实现可开工**（签收范围为规格，实现仍须人工复核），见 §2.2。**P0-14 于 2026-08-07 改判**：不再是 ADR 阻塞——slice 1–3 已落地且有 Android 产物级证据，剩余门槛是 slice 4 红线措辞（owner）、非 Android 平台产物断言、人工安全签收（见 §3.2）|

本轮自动验证：`npm run lint`、`npm run typecheck`、`npm run smoke:all`（server 26/26、tools 18/18）、`flutter analyze`、`flutter test`（744 项）、全量 scanner、release ledger smoke/validate、release preflight、recorder Python tests、`git diff --check`。自动验证不是安全签收的替代品。

| ID | TODO | 主要位置 | 车道与依据 | 完成条件 |
|---|---|---|---|---|
| P0-01 | [x] digest 改为对 envelope 序列化字节整体哈希（digest v2），验签先于解析，验签后过路径卫生闸门 | `tools/src/bundle/envelope.ts`、`package.ts`、`tools/src/signer/index.ts`、`client/lib/core/loader/{bundle,verify}.dart` | 慢车道；签名格式，ADR-002 §2.3 / ADR-018 §2.9.1（2026-09-01 已修订，待 owner 签收） | 验收门 = `tools/src/bundle/path-binding.redcase.ts` 全绿（现 2/14）；TS/Dart 共用新 golden（envelopeBytes 形态）；只改路径必须验签失败；**无迁移**（ledger 为空，`/1` 路径整体删除，不新增 host version gate）；人工签收 |
| P0-02 | [x] 从 UI 会话 API 移除完整 `CredentialStore`，只暴露登录状态、数量、ref、保护等级等元数据 | `client/lib/session/session_controller.dart`、`client/lib/core/credential/` | 慢车道；红线 #1、ADR-012 | UI 包无法取得 `CredentialEntry.value`/`ResolvedCredential.value`；Broker 仍可在核心内解析；边界测试通过；人工签收 |
| P0-03 | [x] 在每次 transport hop 出网前原子预留全局请求配额，修复并发 `ctx.fetch` 超限 | `server/src/runtime/sandbox.ts`、Dart 对应 runtime | 慢车道；Broker/网络边界，ADR-014/022 | 21/100 并发请求的第 21 个在出网前被拒；并发重定向共用配额；双端测试；人工复核 |
| P0-04 | [x] 正确建模 host-only Cookie，禁止无 `Domain` Cookie 发往子域 | `server/src/runtime/broker/cookie-jar.ts`、Dart 对应 Broker | 慢车道；红线 #1 | TS/Dart host-only golden 一致；子域负例零出网凭证；人工复核 |
| P0-05 | [x] 安全策略阻止的重定向必须 fail-closed，不向 adapter 交付 3xx 中间 body/header | `server/src/runtime/broker/redirect.ts`、`fetch-proxy.ts`、Dart 对应实现 | 慢车道；红线 #1、ADR-009/020/026 | allow 外、超 hop、非法 Location 的 token body/header 均不可见；正常终态行为有 golden；人工复核 |
| P0-06 | [ ] 修正 iOS 硬件保护档：采用不可导出 Secure Enclave 密钥包装 DEK，或降级保护等级 | `client/ios/Runner/HardwareKeystorePlugin.swift`、`hardware_secure_store.dart` | 慢车道；ADR-012 | 真机证明密钥不可导出；若降级则显示 S/M 风险提示且不再标 H；人工安全签收 |
| P0-07 | [ ] Android 使用 `KeyInfo` 验证 StrongBox/TEE，软件 Keystore 不得标记为 H 档 | `client/android/app/src/main/kotlin/dev/nancunchild/elecon/HardwareKeystorePlugin.kt` | 慢车道；ADR-012 | 覆盖软件 provider、模拟器、TEE、StrongBox；每类保护等级符合 ADR；人工安全签收 |
| P0-08 | [x] 在客户端核心边界按已验签 manifest 的 `emits.schema/schemaVersion` 严格验证 adapter 输出 | `client/lib/core/adapter_runtime.dart`、`adapter_service.dart` | 慢车道；红线 #6、ADR-008 | 缺字段、错类型、错误 schemaVersion、畸形 item 整体拒绝；UI 不承担契约修复；生成类型/validator 单源 |
| P0-09 | [ ] Masker policy 改为已验签 bundle 的不可选运行时输入；要求 Masker 的 bundle 遗漏装配时拒载 | `server/src/runtime/sandbox.ts`、`fetch-proxy.ts`、Dart runtime | 慢车道；ADR-026 | policy、sink、store 或 host gate 任一缺失均不执行；不允许空规则透明回退；人工安全签收 |
| P0-10 | [ ] 完成 ADR-026 统一 delivery firewall：TS/Dart、declarative/imperative/actuator、Capture/Project/Commit 全入口收口 | `server/src/runtime/broker/delivery-firewall.ts`、`client/lib/core/broker/response_masker.dart` | 慢车道；ADR-026 | 所有响应入口不可绕过；credential 与 handle 事务提交完整；取消/失败无半提交；签收清单关闭 |
| P0-11 | [x] 永久禁止 debug 日志输出凭证 query、fragment、userinfo、Cookie 和 ticket URL | `client/lib/core/debug/dev_log.dart`、`dev_log_page.dart` | 慢车道；红线 #1 | 即使关闭普通脱敏，声明为 credential 的值仍不可见；控制台/UI/错误对象负例通过 |
| P0-12 | [x] 修复 fixture recorder 和探针的凭证落盘/日志风险 | `adapters_tests/XJTU/dean/record_fixtures.py`、`XIDIAN/ids/login.py`、`XIDIAN/energy/meter.py` | 慢车道；红线 #1/#8 | 删除全部 Cookie/Set-Cookie；raw 只能写 `.private-probes/`；不打印 ticket URL/真实 NodeID；scanner 作为写后硬门 |
| P0-13 | [x] 让 release workflow 复用完整 CI，不允许 tag 发布绕过 server/tools/contract/adapter/release gate | `.github/workflows/ci.yml`、`release.yml` | 慢车道；发布与信任链 | reusable workflow 覆盖 lint、typecheck、smoke、validator、scanner、codegen、Flutter、bootstrap、trust profile；tag ancestry 和环境审批有机械验证 |
| P0-14 | [ ] 完成 ADR-024 DEPLOY profile 接线和产物级证明 | `client/lib/core/trust/`、`client/tool/check_release_gate.sh`、release workflow | 慢车道；红线 #4、ADR-024 | release 产物无侧载符号；DEV applicationId/bundle ID 隔离；水印与构建元数据正确；人工签收 |
| P0-15 | [x] 建立 git 跟踪的 adapter 发布台账 | `docs/reference/signing_ceremony.md`、`adapter_release.md`、`release/adapter-release-ledger.json` | 慢车道；ADR-002/018 | 每次发布记录 source commit、版本、bundle/policy digest、catalog/revocation sequence、keyId、签署人与复核引用。**早期测试期产物按 §2.3 显式留白**（`incomplete` 记录 + `missingFacts`），**不要求补齐历史人工事实** |

### 2.2 执行状态（2026-09-01 · P0-01 缺陷复现与 ADR 就地修订）

**缺陷已复现，不再是"理论加固"。** 现行 bundle digest = `SHA-256( SHA-256(C₁) ‖ SHA-256(C₂) ‖ … )`，
文件按相对路径字典序排列——**路径只参与排序、自身从不进哈希**，`encoding`、文件个数与
`bundleFormat` 亦然。于是任何**保持字典序位次的重命名**都不改变 digest，而加载器恰恰是
**按路径**取要执行的字节（`manifest.runtime.entry`、ADR-026 的 `masker.json`）：

```
签名时（受审目录，无害）              伪造后（一个内容字节都没改，只改名）
────────────────────────              ──────────────────────────────────
1  assets/theme.css → EVIL            1  index.js      → EVIL   ← 被执行
2  index.js         → BENIGN          2  index.js0     → BENIGN
3  manifest.json    → MANIFEST        3  manifest.json → MANIFEST
```

两侧「按路径排序后的内容序列」都是 `[EVIL, BENIGN, MANIFEST]`，digest 逐字节相同
（实测 `c3bc2557…ab21`），official 签名验过、身份核对（ADR-002 §2.2）通过、stdlibMin 门通过。
攻击者 = ADR-018 信任域 A 的社区贡献者或任何能把内容放进受审 bundle 的人；**人工审查看到的
是无害目录，检出率为零**。直接击穿红线 #4。

**验收门**：落地前是 `tools/src/bundle/path-binding.redcase.ts`（keyless，只用测试 Ed25519 密钥对），
刻意**不叫** `*.smoke.ts` 以免拖红 `smoke:all`，经 `npm run redcase:bundle-path-binding` 显式运行，
当时 **2/14**（A2 / B1 / C1–C9 / D1 全红）。

**2026-09-09 已全绿并改名**为 `tools/src/bundle/path-binding.smoke.ts`，纳入 `smoke:all`（现 19/19）。
最终 **26/26**，比原计划多出的部分是落地时补的：

| 组 | 断言 |
|---|---|
| A0/A1/A1b/A2 | 保序重命名：含**两条前提断言**——伪造后入口确实解析到恶意内容、且两侧 blob 集合逐字节相同（排除「靠内容变化侥幸拒掉」）|
| B1 | 重复路径 → 即使签名有效也必须拒 |
| C1–C10 | `..` / 内嵌 `..` / POSIX 绝对 / Windows 盘符 / 反斜杠 / `./` / 空 / 尾随分隔符 / NUL / **非 NFC** |
| D1/D2 | 篡改 `bundleFormat`（用原签名）→ 拒；**重签**的 `elecon-bundle/9`（digest 与签名皆真）→ 第 7 步拒 |
| E1–E4 | blob 多（夹带通道）/ 少 / 哈希不符（等长替换，与长度检查分离）/ 长度撒谎 |
| E5–E6 | 三方身份的两条边：envelope 顶层 ≠ manifest、签名载荷 ≠ envelope 顶层 |
| E7a/E7b | 域分隔：无 `contextTag` 的签名、用 `elecon.catalog/1` 域签的签名 |
| E8 | 传输封套含多余字段 |

**ADR 就地修订（未新开 ADR）**：

- **ADR-002 §2.3**：`digest = SHA-256(envelopeBytes)`；原「双层 SHA-256 拼接」规格标注为被取代并
  保留缺陷说明；LF/NFC 规范化由「哈希前静默改写」降级为**构建期检查、不符即拒签**；
  列出四条不可分割的配套纪律（不透明字节上线 / 验签先于解析 / 卫生闸门在验签之后 / 全量文件承诺）。
- **ADR-018 §2.9.1**（新增小节）：上线形态 = **传输封套** `gzip(JSON({ envelopeB64, signature, blobs }))`、
  12 步验证顺序表、签发侧全量文件承诺、10 项落地清单、以及「为何不签压缩包字节」的记录。

**方案论证与被否备选**（四元组叶子编码 / Merkle / 签压缩包字节 / 内联 base64，以及规范化改判、
身份三方一致的理由）已抽出至 [`docs/archive/bundle_digest_v1_superseded.md`](../archive/bundle_digest_v1_superseded.md)，
本文不复述——避免第二份会漂移的转述（2026-09-09 已发生过一次：本节曾把上线形态记成两字段、
验证顺序记成七步）。

**迁移 = 无代码兼容层 + 一次重签仪式**：`records` 为空是 P0-15 台账未建立，不等于未签发——实存
**7 份 official bundle** + 已签 catalog（sequence 3）+ revocation。无外部持有者，故不设双读、不新增
host version gate；但 `/2` 须伴随一次**离线 YubiKey 重签仪式**（5 adapter + catalog + revocation →
`bootstrap:sync` 重派生），**与 ADR-026 §2.7 的「补齐 `masker.json` 后重签」合并为同一次**，并一次
补齐 P0-15 台账首批记录。核实细节见归档 §5。

**暴露面：潜伏但尚未武装**。现存 7 份 bundle 的 `files` 全为 `[index.js, manifest.json]` → 不可利用；
补 `masker.json` 后三者分居三个固定位次 → 仍不可利用。**暴露面在第一份携带运行时资产的 bundle
出现时打开**，故不需紧急吊销，但须在 adapter 开始携带资产前落地（充要条件见归档 §5）。

**2026-09-01 owner 复核后的五项裁定**：

| # | 裁定 | 状态 |
|---|---|---|
| 1 | envelope 从「容器」降为「清单」：`files[]` 存 `path/size/sha256`，文件字节改由**按内容哈希寻址**的 blob 表承载 | 已写入 ADR-002 §2.3 / ADR-018 §2.9.1 |
| 2 | envelope 顶层新增 `adapterId/adapterVersion`，身份核对改为**三方一致**（签名载荷 ↔ envelope ↔ manifest） | 同上 |
| 3 | 三处签名统一加显式域分隔：`contextTag ‖ 0x00 ‖ 被签字节` | 同上（落地清单 #3） |
| 4 | ~~从 manifest 移除 `trustTier`~~ → 改为**意图档位作为签发流水线显式入参** | **已落地**（分支 `refactor/intended-tier-as-pipeline-input`）。直接删字段会静默拿掉 validator 三道签发期闸门（C3 / `ssoMint` official-only / masker official-only）并撞上 ADR-033 §5「C3 不得先删」。改为：三道闸门 + `release/package.ts` 改读显式 `IntendedTier` 入参；`trustTier` 从 `required` 移出、降为过渡期回退（分歧=error 且以入参为准）。**C3 保留**，其退役仍随 ADR-033 |
| 5 | digest v2 重签仪式与 ADR-026 §2.7 的「补齐 `masker.json` 后重签」合并，一次补齐 P0-15 台账首批 | 已写入两处 ADR |

**红用例已扩**：`path-binding.redcase.ts` 末尾曾以清单形式钉住 descriptor 落地后须补的 E1–E8 断言
（blob 多/少/哈希不符/长度不符、三方身份两例、域分隔、传输封套多余字段）——当时类型无法表达，
故不伪造为通过。**2026-09-09 落地时已全部实现并转绿。**

**剩余门槛（🔒 人工）**：

- ~~① owner 签收上述两处 ADR 修订~~ → **已完成：owner NanCunChild 于 2026-09-09 正式签收
  ADR-002 §2.3 与 ADR-018 §2.9.1，两处规格状态为「已接受并完成审阅」。P0-01 自此可开工。**
  签收范围是**规格**，不含实现——实现落地后仍须按下面 ② 单独人工复核。
- ② 实现本身触红线 #4，须人工主导 + 安全清单 + ≥1 人工审，**AI 不得独自闭环**（AGENTS.md §1）。
- ③ 顺带发现、须一并处理的两处不对称：TS `verifyBundleSignature` 缺 `bundleFormat` 检查（Dart 有）、
  `unpackBundle` 现为「先解析后验签」。**已解决**：两端唯一入口都改成收**原始字节**的 `openBundle`，
  「先解析后验签」在 API 形状上不再可能表达。

### 2.3 执行状态（2026-09-09 · P0-01 规格签收 / P0-15 早期台账合法留白）

**P0-01 规格签收。** owner NanCunChild 于 **2026-09-09** 正式签收 ADR-002 §2.3 与 ADR-018 §2.9.1，
两处状态更新为「已接受并完成审阅」。**P0-01 自此不再受 ADR 阻塞，可以开工。**
签收范围**仅为规格**；实现触红线 #4，落地后仍须人工主导 + 安全清单 + ≥1 人工审（AGENTS.md §1）。
验收门不变：`tools/src/bundle/path-binding.redcase.ts` 全绿（现 2/14），全绿后改名纳入 `smoke:all`。
→ **2026-09-09 已落地，见 §2.4。**

**P0-15 早期台账合法留白（owner 决策 2026-09-09）。** 现存 7 份 official bundle 均为**早期测试阶段**
产物，其 `sourceCommit` / `signedAt` / `signer` / `reviewReference` 四项人工事实**不予追溯补齐**，
按「合法留白」处理。

- **留白的形式不是「空台账」。** `release/adapter-release-ledger.json` 现为 `records: []`，
  即「什么都没说」——这与「说清楚了哪些不知道」是两回事，后者才可审计。ledger 工具**本就为此而建**：
  记录支持 `status: "incomplete"` + `missingFacts: []`，校验器对 incomplete 记录**不报错**，
  只如实输出 `historical completeness: incomplete (N of M)`。
- **机器事实必须齐全。** `ledger:extract` 对 catalog / revocation / 每份 bundle 做**预埋公钥 Ed25519
  验签**后才产出记录，故 `adapterId` / `adapterVersion` / `bundleDigest` / `keyId` /
  `catalogSequence` / `revocationSequence` 全部有密码学依据，**不是人填的**。留白的只有四项人工事实。
- **台账从 digest v2 重签仪式起转为 complete。** 那次仪式（5 adapter + catalog + revocation，
  与 ADR-026 §2.7 的 `masker.json` 重签合并）是**首批四项人工事实齐全**的发布，此后每次发布均须 complete。
- **P0-15 的完成条件据此改判**：不再是「补齐历史事实」，而是「**台账已建立且结构有效；早期产物以
  incomplete 显式留白；重签仪式起的记录 complete**」。§2.1 表格中「由 NanCunChild 提供历史
  source commit/签署时间/签署人/复核引用」一项**作废**。

**已执行（2026-09-09）**：对三份 dist 跑 `ledger:extract`（预埋公钥
`elecon-official-ncc-1` / `d09437aa…2687`）→ **7 条**验签通过的记录，独立印证了
「实存 7 份 official bundle」的核实结论。台账现有 **6 条** incomplete 记录，
`historical completeness: incomplete (6 of 6)`。

**🔴 提取时发现一处真实异常：`school-helloworld@0.1.0` 被签发了两次，字节不同。**

| catalog seq | digest | manifest 差异 |
|---|---|---|
| 1（已被取代） | `e3bf71af…` | 含 `"mode": "fetch"` |
| 3（当前在役） | `8a6ab755…` | 无 `mode`，改为 capability 级 `"requestGraph": "imperative"` |

即 **ADR-022 的 `mode` → `requestGraph` 迁移后重签了产物，但版本号没动**。
`ledger:validate` 的 equivocation 检查据此拒收（`records[3] duplicates or equivocates an
earlier adapterId+adapterVersion`）——**它是对的**：「版本号唯一标识一份字节」是台账的硬不变量，
两份不同字节共用 `0.1.0` 违反它。

- **实际影响：低。** 两份都经 official 验签；bundle 缓存按 digest 寻址、取哪份由 catalog 决定，
  故运行时不会混淆；helloworld 是演示 adapter，不碰真实数据。
- **但不能静默处理。** 台账入库时**显式剔除**了 seq 1 那条（已被取代），本节即该剔除的记录——
  「合法留白」的前提是留白**被写下来**，而不是让它消失。
- **流程修正**：**契约迁移后重签必须 bump 版本号。** 重签改变了字节即改变了那个版本的含义，
  沿用旧版本号会让台账、缓存与吊销推理同时失去锚点。此条应在 digest v2 重签仪式的
  checklist 里落为一步（见 `docs/reference/signing_ceremony.md`）。
- **由该仪式一并了结**：digest v2 重签会给全部 5 份产物新的 digest，届时 helloworld 应
  bump 到 `0.1.1`（或更高），历史歧义随 `/1` 路径整体删除而失效。

---

### 2.4 执行状态（2026-09-09 · P0-01 digest v2 两端落地）

**状态：代码已落地、两端 CI 全绿；人工安全复核已签收（2026-09-11，PR #111，见 §2.6）；重签仪式已于 2026-09-11 执行（§2.7）。**

验收门 `path-binding.smoke.ts` **26/26 全绿**；tools `typecheck` 0 错、`smoke:all` 19/19；
client `flutter analyze` 0 问题、`flutter test` **856 通过 / 12 skip**。跨语言 golden
`contract/golden/bundle/loader.json` 现 **19 条向量**，两端跑同一份线上字节。

**外部一致性证据（最强的一条）**：`elecon-adapters/scripts/build-bundle.mjs` 与核心
`tools/src/bundle/envelope.ts` 是**两份独立实现**，对真实 adapter `school-xidian@0.4.1`
产出的 envelopeBytes **319 B 逐字节相同**，digest 同为 `6e6f196c…f991`。ADR-002 §3 风险 5
（跨实现漂移）在签发侧因此有了可复算的实证，而不只是「两边都照 ADR 写了」。

#### 落地时新增的三项决策（均超出 2026-09-09 已签收的规格文字；**owner 已于 2026-09-11 逐项签收**）

| # | 决策 | 起因与理由 |
|---|---|---|
| A | **路径段字符集收紧为 `[A-Za-z0-9._-]`**，卫生闸门不再依赖 Unicode 规范化 | TS 有 `String.normalize("NFC")`，**Dart 没有内建 NFC**。若 Dart 略过该检查，两端卫生闸门对同一份 bundle 给出**不同判定**，且 Dart 方向是 fail-open——这正是风险 5 的活样本；给 Dart 引入第三方 NFC 实现只是把漂移面换个地方。收紧字符集则从源头消灭该问题：该集合内不存在非 NFC 形式，也不存在同形异码与 RTL override。**代价**：adapter 内文件名不得含非 ASCII（现有全部 adapter 均满足，且这是内部打包路径，与任何面向用户的展示文本无关）。TS 侧保留 NFC 断言作零成本的第二道锁。golden 用例 `non_ascii_path` 钉住两端同判。 |
| B | **验签层不做档位门，档位门归加载器** | TS `openBundle` 服务于台账提取、签发侧自验等**非加载**场景，那里需要「密码学事实」而不需要「加载策略」；把 official-only 塞进去会逼这些调用方接受一个会拒 sideload 的 API。故 TS 侧 `ok + tier=sideload`，Dart 侧（它**是**加载器）第 12 步拒。golden 用例 `valid_signature_sideload_tier` 带 `loaderMustRefuse` 标记，同时钉住这两件事。**这一项是被 golden 生成器的自验揪出来的**——原先的期望写的是「验签层应拒」，与 TS 实际行为不符。 |
| C | **`*.md` 进 `BUNDLE_EXCLUDE` 显式排除名单** | 全量文件承诺（纪律 5）一开，**现有每个 adapter 都签不出来**——`README.md`/`COVERAGE.md` 既不在 INCLUDE 也不在 EXCLUDE。按该纪律自身指明的出路处理：显式排除，名单进版本控制即为审计记录。排除 ≠ 夹带面（被排除的文件根本不进 bundle，永远到不了客户端）；纳入才是把几十 KB 无用字节推给每个终端用户。 |

#### 顺带完成的简化（对应「简化心智以提升维护效率」）

- **两端唯一入口都改成收原始字节的 `openBundle`**。v1 的 `verifyBundleSignature(env, sig)`
  这个签名本身就违反「验签先于解析」——一旦 envelope 已是对象，「验的字节」与「用的字节」
  就分了家。改成收字节后，这类错误**在 API 形状上不再可能表达**。
- **`VerifiedBundle` 携带内容**（`envelope` / `envelopeBytes` / `blobs`），`LoadResult` 只存这一个
  对象、其余字段降为 getter。原先 envelope / identity / digest 三份平行字段可能互相不一致，
  `adapter_launcher.dart` 为此写过一条「防手工构造的不一致 LoadResult」的冗余检查——现已删除，
  因为那种不一致构造不出来了。（对应测试也从「伪造 LoadResult」改写为「把 A 的凭据配 B 的内容」，
  那才是仍然构造得出的错配形态。）
- **`BundleCache.read` 只返回裸字节**，不再吐 `CachedBundle{envelope, signature}`。缓存层因此
  不再有第二份解析实现，「未验签的 envelope」这个危险中间态在类型上不存在。
- **删除 `computeBundleDigest` / `verifyAdapter` / `signAdapter`**：保留「从目录直接算 digest」
  的旁路等于第二条 digest 实现，必然与 `buildEnvelope` 漂移。CLI `digest` 子命令改走同一条实现。
- **新增 `client/test/utils/bundle_fixture.dart`**：六个测试文件原先各自手拼 `BundleEnvelope`
  字面量，每份手拼都是一份可能漂移的影子实现。收敛后测试只描述「这个 bundle 里有哪些文件」。
- **golden 生成器自带自验**：每条向量的期望必须是 TS 侧**真实产生**的行为，否则拒绝写出——
  否则 golden 只是一份「我以为会这样」的手写清单，写错了会把 Dart 钉到错误的行为上。

#### 剩余门槛

| # | 事项 | 归属 |
|---|---|---|
| 1 | ~~🔒 人工安全复核~~ **已完成（2026-09-11）**：owner 按 [`bundle_digest_v2_signoff_checklist.md`](../reference/bundle_digest_v2_signoff_checklist.md) 逐文件 / 攻击场景复核，首轮 4 条意见修复后复签，随 PR #111 合并 | owner |
| 2 | ~~🔒 签收上表 A/B/C 三项决策~~ **已签收（2026-09-11）** | owner |
| 3 | ~~**离线 YubiKey 重签仪式**~~ **已执行（2026-09-11，§2.7）**：仓内 7 份 v1 产物在 v2 下一律拒载（item 8「无代码兼容层」的预期行为）。`client/test/school_manifest_test.dart` 的 bootstrap 用例已做**条件跳过**——一旦重签为 v2 自动恢复运行，不依赖任何人记得回来删一行 | owner（物理动作） |
| 4 | 重签时 bump 版本号——**不只 helloworld，全部 5 份**（§2.5 核实）；2026-09-11 已在 A 仓 bump fudan/thu/xjt/helloworld 0.1.0 → 0.1.1，xidian 0.4.1 未签发过不动 | 已做 |
| 5 | `elecon-adapters` 侧两处规则同步（详见下表） | 与 A 仓同批 |

#### `elecon-adapters` 侧待同步（截至 2026-09-09 比对）

`scripts/build-bundle.mjs` 已自行迁到 v2 且与核心逐字节一致，**只余三处**：

| 处 | 现状 | 应改为 |
|---|---|---|
| `assertPathHygiene` | 只有 NFC 检查，**无字符集白名单** | 补 `[A-Za-z0-9._-]` 段白名单（决策 A）。否则本仓能构建出核心**拒签**的 envelope——签发侧比验端宽，是最难查的一类不一致 |
| `BUNDLE_EXCLUDE` | `\.md$`（大小写敏感） | `\.md$` 加 `i` 标志，与核心一致；否则 `README.MD` 会走到「全量文件承诺失败」而非被排除 |
| 文件头 / `catalog.mjs` 的 ⚠ 提示 | 「核心 signer / 客户端加载器当前仍在 `elecon-bundle/1`，digest 预检暂不可用，产物暂不可加载」 | **已过时**：核心两端已是 v2，digest 预检自此成立（实证见上）。产物仍不可直接加载，但原因变成「未签名」而非「格式不符」 |

另有一处**先于 digest v2 存在**的红：`grades.list` 的 registry 已到 `1.1`，而 pinned adapters
仍声明 `1.0` → `C2_emits_mismatch`（`school-thu` / `school-xidian`）。与本次改动无关，随 A 仓同步解决
（**2026-09-10 已在 A 仓修复**，见 §2.5）。

---

### 2.5 执行状态（2026-09-10 · 重签仪式前置核查）

**结论：仪式此刻做不了。** 落地后对「拿起 YubiKey 之前还差什么」做了一次实测核查，查出 **3 个硬阻塞
+ 2 处现有文档低估的事实**。本节是仪式的前置清单，全部清空之前不要开始。

#### 硬阻塞

| # | 阻塞 | 证据 | 归属 |
|---|---|---|---|
| 1 | **5 个 official adapter 里 2 个过不了 validator** | `--intended-tier=official` 逐个实跑：`school-fudan` ✓、`school-xjt` ✓、`school-helloworld` ✓；`school-thu` ✗、`school-xidian` ✗ 均为 `C2_emits_mismatch`（manifest `elecon.grades.list@1.0` vs registry `@1.1`） | A 仓 —— **2026-09-10 已修**（两份 manifest bump 到 `1.1`；见下「已解决」） |
| 2 | **带 `masker.json` 的 bundle 签不出来** | `tools/src/validator/index.ts` 的 `RM0_host_gate_unavailable` 是**无条件 error**：只要 adapter 根有 `masker.json`，即使策略合法也拒绝签发 | 已由 **ADR-026 §2.7.1（2026-09-10 owner 决策）** 定出路：gate = `bundleFormat` 断代到 `/3`，与移除 RM0、loader 接线同批。**故本次仪式不带 `masker.json`**，见下「排期后果」 |
| 3 | ~~🔒 人工安全复核必须排在仪式之前~~ **已解除（2026-09-11 签收）** | 仪式是拿 official 私钥为这套验签实现背书；复核未做即签 = 用未复核代码铸造正式信任 | owner，顺序不可换 |

#### 两处现有文档低估的事实

- **🔴 五个 adapter 全部都要 bump 版本号，不只 `school-helloworld`。** §2.3 只写了 bump helloworld
  （equivocation 修正）。但台账的硬不变量是「**版本号唯一标识一份字节**」，而 v1→v2 重签会改**每一份**
  产物的字节：`school-fudan@0.1.0` 若沿用旧号，`ledger:validate` 会和 helloworld 那次一样判
  equivocation。**结论：`school-fudan` / `school-thu` / `school-xidian` / `school-xjt` /
  `school-helloworld` 五份的 `adapterVersion` 全部必须 bump。**
- **🟠 `release/revocation.json` 早已过期。** 现为 `sequence: 1`、`issuedAt: 2026-07-19`、
  `ttlSeconds: 604800`（7 天）→ **2026-07-26 即过期**。P3-08 的新鲜度门一上线就会拒。
  仪式时须 bump 到 `sequence: 2` 并更新 `issuedAt`。

#### 排期后果（ADR-026 §2.7.1 决策的直接推论）

本次仪式**不带 `masker.json`**（RM0 未移除、loader 未接线）。因此存在一个**会随时间关闭的窗口**：

> `/2` 的 `bundleFormat` 严格相等挡得住 v1 host，**挡不住「懂 `/2`、但没有 masker 运行时门」的 host**。
> 这种 host 现在一个都不存在（v2 代码尚未发版）。

§2.7.1 的断代决策把这个窗口换成了常量——masker 强制那一跳一律断到 `/3`，故**即使本次仪式后发布了
v2 客户端，安全性也不依赖排期**。代价是 masker 落地时需要**第二次重签仪式**，这是已知且已接受的。

#### 仪式当天的参数（核查所得）

| 项 | 值 | 依据 |
|---|---|---|
| `--sequence=` | **4** | 线上 catalog 现为 3（`dist-full/catalog.json.gz` 实读） |
| revocation | bump 到 `sequence: 2` + 刷新 `issuedAt` | 见上，现值已过期 |
| `--adapters=` | 指向**含全部 5 个 official 目录的同一个根** | `adapter_release.md` §4 注意：只传单个目录时线上 catalog 会被缩成单条。而 `school-helloworld` 在核心仓 `adapters/`、另 4 个在 `.adapters-cache/`，**须先拼一个「全集 release 根」** |
| 签前 digest 重算 | 不可跳过 | `adapter_release.md` §3——「所见非所签」的唯一防线，必须在**即将触碰的那台机器**上算 |

#### 仪式后的收口

```bash
npm run bootstrap:sync                 # 重派生 client/assets/bootstrap/
cd ../client && flutter test           # school_manifest_test 的条件跳过应自动恢复
cd ../tools && npm run ledger:extract  # 补 4 项人工事实 → status: complete
npm run ledger:validate                # 应不再是 incomplete (6 of 6)
```

→ **P0-15 可关闭**；**P0-01 可关闭**（前提：上表阻塞 3 的人工复核已签）。R2 退出条件同时满足。

#### 已解决（2026-09-10）

- **A 仓 `grades.list` 1.0 → 1.1**：`school-thu` / `school-xidian` 两份 manifest 的
  `emits.schemaVersion` 已 bump，两者现均通过 `--intended-tier=official` 校验。依据
  `contract/CHANGELOG.md`（2026-09-08 条目）与
  [`gradepoint_ownership_landing.md`](../reference/gradepoint_ownership_landing.md) §4.1 —— 该升级是
  **MINOR**（仅新增两个可选字段），旧 1.0 数据在 1.1 下仍合法，故无须改 `index.js` 或 fixture。
  - **未同批（非阻塞，须人工事实）**：§4.1 的「同批建议」——这两个 adapter 在产出里加
    `gradePointScale`（西电为 4.3 制**需人工确认**、清华**需确认**）并对来源直接给出的绩点标
    `gradePointSource: "source"`。**不做则客户端 GPA 按 fail-closed 不显示**（尺度不明不展示）。
    这不阻塞签发，但会让 GPA 在重签后仍然空着。

---

### 2.6 执行状态（2026-09-11 · CI 恢复 + 仪式前置收口）

**起因**：main 的 CI 自 2026-08-27 起持续红（两次 run 同型失败），且本地 main 与 origin/main 分叉
（origin 有 PR #110 的合并提交，本地领先 9 个提交含 digest v2 全部代码），A 仓另有 4 个提交未推。

| 红项 | 根因 | 处置 |
|---|---|---|
| server `smoke:all` 27/28（`adapters-xidian.card.imperative`） | `adapters.pin` = `49ae7f5` 早于 A 仓 card 支持（A 仓 main 早已有 `card.*`），核心从未 bump pin | pin bump → `ba7f190`（含 card.*、grades.list 1.1、bundle/2） |
| tools `validate`（推送后必红） | grades.list 契约 1.1 在未推送提交里；A 仓修复 `76ce7fc` 未推 | A 仓 4 个提交已合并 bot 镜像后推到 ncc-devlab main；同上 pin |
| tools `check:contract-changelog`（PR 上红） | tools job 浅克隆无 `origin/main`，门报「找不到 base ref」；push 到 main 时 base==HEAD 零差异假绿，故此前从未在 PR 上真正生效 | tools job checkout `fetch-depth: 0` |
| `client-android-emulator` | runner 无 `/dev/kvm` 权限（日志 `ProbeKVM ... doesn't have permissions`），x86_64 模拟器无加速 → adb 永不可达。**非代码问题** | `ci.yml` 加 android-emulator-runner 官方要求的 Enable KVM 步骤（udev 规则） |

**签发侧跨实现一致性（ADR-002 §3 风险 5）扩到全部 5 份**：A 仓 `npm run bundle` 与核心 `signer digest`
对 `school-fudan/helloworld/thu/xidian/xjt` 的 sha256 **逐一相同**（此前只核过 xidian 一份）。

**P0-13 剩余门槛已核实为事实（owner 2026-09-11 勾选关闭）**：GitHub API 实读——`release` Environment 存在且带
`required_reviewers` + `branch_policy`；tag ruleset 对 `refs/tags/v*` 启用 `creation`/`update`/`deletion`
三条规则（不可变 tag）。§2.1「仍需配置 `release` Environment、不可变 `v*` tag 规则」一项据此**作废**。

**复核入口**：digest v2 实现的人工安全复核清单已建为
[`bundle_digest_v2_signoff_checklist.md`](../reference/bundle_digest_v2_signoff_checklist.md)
（逐文件 / 攻击场景 ↔ 红用例 / 决策 A/B/C）。签完即 §2.5 阻塞 3 解除。

**本轮自动验证**（HEAD + 工作树）：biome / typecheck / `git diff --check`、tools smoke 19/19、
ledger:validate、scan、codegen 漂移、bootstrap:check、changelog 门、validate-dist 全过；
`flutter analyze` 0；`flutter test` DEPLOY 856 通过 / 12 skip、DEV 865 通过 / 3 skip。
pin bump 到 `ba7f190` 后复跑：server smoke **28/28**（card 项转绿）、tools validate **校验通过**（C2 消失，
仅余 C0 意图档位 warn）、tools smoke 19/19、`flutter test` DEPLOY 856 通过 / 12 skip（skip 仍为等重签的
`school_manifest_test` 条件跳过）。

**owner 首轮复核（2026-09-11）**：4 条意见，1 条实质偏差——TS 端 base64 宽松解码与 §2.9.1 第 3 步矛盾。
已修为两端统一的规范形解码（并顺带关掉 Dart 接受 URL-safe 字母表的反向不对称），红用例 E9a–E9d、
golden +2（现 21 条）。其余为清单措辞与过期注释，已改。记录见签收清单 §6。

**待办（本节落地后）**：~~① owner 按签收清单复核~~（2026-09-11 已签，PR #111 合并）；~~② 仪式前在 A 仓 bump `school-fudan/thu/xjt/helloworld`
`adapterVersion` 0.1.0 → 0.1.1（`school-xidian` 已是未签发过的 0.4.1，不动）~~（2026-09-11 已做，核心 `adapters/school-helloworld` 副本同步）并把 pin 移到该提交（`444b92c`，已做）；
~~③ 举行 §2.5 所列参数的仪式~~（2026-09-11 已执行，见 §2.7）；~~④ 合并后 `git branch -f main origin/main`~~（已做）。

### 2.7 执行状态（2026-09-11 · digest v2 重签仪式执行，P0-01 / P0-15 关闭）

**仪式跑了两趟。** 第一趟由 owner 自行执行（catalog issuedAt 06:28Z）：`--sequence=7` 而非 §2.5
预定的 4——7 **合法**（客户端 `pickNewer` 与台账 validator 都只要求严格大于上一份 3，允许跳号），
但 `release/revocation.json` 未按 §2.5 参数表刷新（仍是 sequence 1、issuedAt 2026-07-19，2026-07-26 即过期，
仅签名字节变了）。加载器对过期 revocation 只做遥测不硬拒（`loader.dart` 文件头政策），所以不影响加载，
但这正是 P3-08 要挡的情形。第二趟（06:34Z，AI 起草参数、owner 触碰）：revocation 改为 **sequence 2 /
issuedAt 2026-09-11T06:31:00Z**，以 `--sequence=8` 重签全部产物；bundle digest 不变（签名在 envelope 之外），
只有签名字节变。**线上有效序号自此为 catalog 8 / revocation 2；下次发布 catalog 须 ≥ 9。**

| adapterId | adapterVersion | digest | 源 |
|---|---|---|---|
| school-fudan | 0.1.1 | `59c632d58996c5c5759a70d15644a189b9cc730944dd0a66695138dbc550dabf` | A 仓 `444b92c` |
| school-helloworld | 0.1.1 | `ebc14c0306dee2a95c279e3238134f6fc60fae4584c77c30791ca06e077eda6c` | 同上 |
| school-thu | 0.1.1 | `cba878ad987c0adf30a705093254a82a9d3986f026fdc894d33fce6565f03f6a` | 同上 |
| school-xidian | 0.4.1 | `6e6f196c049c30ffd100058d84f43557ee4a47509aef83c612df2f2e3440f991` | 同上 |
| school-xjt | 0.1.1 | `64fde67426d615d61ee56d4585ef60443be4493823f68f3257218da5c95965a0` | 同上 |

**核验**：签前 digest 在签名机重算 5/5 与 A 仓 `dist/bundles/*.sha256` 相同（§3「所见即所签」）；
`ledger:extract` 以预埋公钥对 catalog、revocation、5 份 bundle **真实验签通过**；`bootstrap:sync` 派生 7 文件、
`bootstrap:check` 一致。**P0-15 台账**：5 条新记录 `complete`（sourceCommit `444b92c…`、signedAt
`2026-09-11T06:34:22Z`＝最后一次触碰、signer NanCunChild、reviewReference = PR #111 + 签收清单 §5），
6 条历史记录按 §2.3 保持 `incomplete`；`ledger:validate` 结构有效。

**顺带清理**：`client/assets/bootstrap/bundles/` 里 5 份旧 v1 bundle 删除（`bootstrap:sync` 不清理多余文件，
pubspec 按目录打包，否则会随 app 发布）；`dist-helloworld/`、`dist-xidian/` 删除，**`dist-full/` 为唯一 dist**
（P3-07 方向；`adapter_release.md` §0–§7 与 `tools/README.md` 已改指，§8 保留为 v1 时代范例）。

**本轮自动验证**：`flutter test` DEPLOY **859 通过 / 11 skip**（skip 全为 DEV profile 专属组；
`school_manifest_test` 条件跳过已自动恢复）、tools smoke 19/19、server smoke 28/28、tools validate 通过、
`git diff --check` 干净。

**关闭**：P0-01、P0-15（§2.1 打勾）。**仍开**：上传 `dist-full/` 到端点 D（运维动作，线上 catalog 仍为 3）；
masker 落地时第二次仪式（`/3`，ADR-026 §2.7.1）；P3-08 发版门（本次第一趟即其反例）。

### 2.8 执行状态（2026-09-11 · catalog 去端点化 + bootstrap 单源 + 文档收敛）

**背景**：公网端点暂不可用，bundle 加载测试只能本地跑；而 catalog 把 `--base-url` 签进了字节，
真机无法指向本地端点，换域名 / 镜像也都要重签。owner 当日四项决策（详见 ADR-018 §2.5.1）：

1. **catalog 只描述文件、不描述端点**：entry `url` 弃用（schema 留可选兼容 seq ≤ 8，下次仪式后删）；
   `release:package` 移除 `--base-url`；客户端 `fetchBundle(digest)` 按 `base/bundles/<digest>.json.gz` 拉取，
   digest 形态门 + 解析时整段忽略 `url`。契约改动记 `contract/CHANGELOG.md`（2026-09-11 条）。
2. **client 自持 base URL**（`kDistributionBaseUrl`）；**仅 DEV-Sideload** 可 `--dart-define=ELECON_DISTRIBUTION_BASE_URL=`
   覆盖（允许 http，供本地 nginx / `npm run start:public` 冒烟）；DEPLOY 编译期折叠无覆盖路径。
3. **dist 树不入库，只有 bootstrap 跟随**：`git rm --cached dist-full`，`.gitignore` 加 `/dist/`、`/dist-*/`；
   `bootstrap.ts` 新增 `--verify`（CI 门，替代原 `bootstrap:check`）与 `--export-dist=`（上传前反向导出；
   bundle / revocation / 内层 catalogJson 逐字节等于仪式产物，gzip 外壳不在签名范围内）。P3-07 关闭。
4. **文档心智收敛**：AGENTS 红线 #4/#5 精简为不变量本身（transport 历史留在 `docs/archive/adr_003_revision_log.md`）；
   README 传输底座措辞对齐 09-09 决策、路线状态改为「只认两处」指针；`docs/notes/` 三份 7 月草稿、7 月路线图、
   根目录 `TODOList_schema_extend.md` 归档到 `docs/archive/`（未完项并入 §6.2）；`adapter_bundle_primer.md`
   改为常设文档；新增 `docs/glossary.md` 术语索引。

**验证**：tools `typecheck` + smoke 19/19（含新增 bootstrap verify/export 往返与负例、catalog K3、release 无 url 断言）；
`bootstrap:verify` 对入库 bootstrap（seq 8）通过；client `flutter analyze` 零问题，`flutter test` DEPLOY 859 / DEV-Sideload 868 通过
（含 `fetchBundle(digest)` 拼路径、畸形 digest 拒、http base 仅 `allowInsecureHttp` 放行、历史 `url` 忽略）；`biome ci` 通过。

**🔒 待人工**：本批触红线 #4（loader / distribution 路径）与 #6（catalog schema），实现须 owner 复核签收；
DEV 覆盖开关的 http 放行需在签收时确认「仅 DEV profile 可达」（`kDistributionOverrideActive` 为编译期常量，
ADR-024 release gate 另断言 DEPLOY 无 DEV profile）。**仍开**：上传端点 D（现由 `npm run dist:export -w tools` 导出后上传）；
第二次仪式后从 schema / 客户端删除 `url`。

---

## 3. P1：核心正确性与契约闭环

| ID | TODO | 主要位置 | 前置 | 完成条件 |
|---|---|---|---|---|
| P1-01 | [ ] Credential Store 按用户、学校、ref 隔离，或用类型保证 store 单租户 | `client/lib/core/credential/`、`server/src/runtime/credential/` | P0-02 | 两校同名 ref 不覆盖；resolver 绑定执行上下文；迁移旧数据；人工复核 |
| P1-02 | [x] 修复 H/S 持久化队列首次失败后永久中毒 | `software_secure_store.dart`、`hardware_secure_store.dart` | 无 | 首写失败后后写可恢复；durability failure 可见；无静默内存成功 |
| P1-03 | [x] 登出改为等待 `delete + flush` 的异步事务 | `session_controller.dart`、`settings_page.dart` | P1-02 | 删除未落盘时不得显示完成；失败有安全错误；立即重启不恢复旧凭证 |
| P1-04 | [ ] 保留重复响应头的原始多值语义，Masker 基数检查发生在折叠前 | `server/src/runtime/transport/direct.ts`、Dart transport、Masker | P0-09 | 两个同名 token header 触发 ambiguous fail-closed；双端真实 HTTP 测试 |
| P1-05 | [x] 修复同名不同 Path Cookie 的选择与排序 | `server/src/runtime/broker/cookie-jar.ts`、Dart 对应实现 | P0-04 | `/` 与 `/api` 同名 Cookie 行为符合明确策略/RFC；双端 golden |
| P1-06 | [x] 补齐 Cookie 的 Secure、Max-Age、Expires 和删除语义 | TS/Dart CookieJar | P0-04 | HTTPS/HTTP、过期、`Max-Age=0`、覆盖删除均有共享 golden |
| P1-07 | [ ] Transport 解压 body 后清理或重算 `Content-Encoding/Content-Length` | `server/src/runtime/transport/direct.ts`、Dart transport | 无 | gzip/br 响应交给 adapter 时 body 与实体头一致；双端测试 |
| P1-08 | [ ] Masker 支持并事务提交 `destination.kind: handle` | TS/Dart Response Masker 与 dataflow runtime | P0-10 | staged handle 与 credential 同事务；失败不激活旧/半成品 generation；共享 golden |
| P1-09 | [ ] ADR-026 policy 按最终 URL、status、Content-Type 匹配并合并多条规则 | `contract/response-masker.schema.json`、validator、runtime | P0-09；需按 ADR-026 慢车道 | schema、validator、TS/Dart runtime 一致；host gate 生效；人工签收 |
| P1-10 | [ ] 落地 ADR-031 `seed`、`material`、D17-D21 和 hydrate 边界 | manifest、validator、TS/Dart dataflow、Credential Store | P0-10；ADR-031 | material 只进入句柄空间、不走 HTTP 注入；预算/缺失/failure 测试；人工签收 |
| P1-11 | [ ] 落地 ADR-029 固定 body 模板和受限 body credential inject | manifest、validator、TS/Dart Broker | P0-10、P1-10；ADR-029 | 仅固定字段/模板可注入；adapter 不见值；重定向与日志规则闭合；人工签收 |
| P1-12 | [ ] 完成 ADR-030 actuator 统一副作用闸门 | contract registry、Broker、UI action entry | P0-10、P1-11；ADR-030 | 仅用户手势触发；禁自动重试；状态未知语义；固定 endpoint；审计与人工签收 |
| P1-13 | [ ] manifest validator 强制 `requests[].key` 唯一，runtime 纵深拒绝重复 key | `contract/manifest.schema.json`、`tools/src/validator/`、TS/Dart runtime | 需确认是否仅 validator bugfix或契约增补 | 重复 key 在签发前和运行时都失败；bind/Masker 负例覆盖 |
| P1-14 | [x] registry 有 params 时，manifest 必须声明完全一致的 params binding | `tools/src/validator/index.ts` | 无 | 缺 params、错 schema、额外 params 均硬错误；template 回归通过 |
| P1-15 | [ ] 分层关闭 manifest 安全面未知字段 | `contract/manifest.schema.json` | 慢车道；需兼容性方案 | 已删除 `mode`、拼错字段和未知安全声明均失败；旧 bundle 迁移策略明确 |
| P1-16 | [x] 修正 declarative/imperative 模板的 `gradePoint:null` 和未知课程类型映射 | `adapters/_template/*/index.js` | P0-08 | 可选字段缺失时省略；未知类别为 `unknown`；真实 replay+schema+golden 通过 |
| P1-17 | [ ] 建立真正的 adapter fixture replay 门，而不是只校验 expected JSON | `tools/src/validator/`、adapter fixtures | P0-08 | replay 请求/dataflow/handler 后逐字段比较 expected 并校验 schema；输入链缺失会失败 |
| P1-18 | [x] 修复 external adapter 根环境变量不一致 | `scripts/fetch-adapters.sh`、`tools/src/validator/index.ts`、CI | 无 | CI 输出实际扫描目录和 adapter 数量；pinned adapters 全量 validator 确实运行 |
| P1-19 | [x] adapter discovery 排除 `graphify-out`、缓存和非 adapter manifest | `tools/src/validator/index.ts` | 无 | 本地 graphify 后全量 validator 不误扫；只识别合法 adapter 根 |
| P1-20 | [x] 修复 `adapters_tests/XIDIAN/jwc/std` 的 entry、schemaVersion、日期和手写校验器漂移 | 对应 manifest/index/run | P0-08 | 使用标准 fixture/replay；坏日期省略；UTC 归一；validator 零错误 |

### 3.1 执行状态（2026-08-06）

- P1-14：validator 已把 params 双向一致设为硬门；外部 manifest 修复钉死在 `elecon-adapters@49ae7f53c380eb40bd283b8dc36ccda1c2a26774`（`elecon-adapters#3`）。
- P1-17 部分落地，保持开放：validator 已把 fixture expected 和输入链设为硬门；server 对 pinned adapter 的 8 个 fixture 真实执行 QuickJS handler、逐字段比对 expected 并校验 schema。尚缺 declarative request/dataflow host 的完整编排 replay，不能仅凭 handler replay 关闭。
- P1-16：declarative/imperative 模板均通过真实 QuickJS replay；缺失 `gradePoint` 时省略，未知课程类型归一为 `unknown`。
- P1-18/P1-19：拉取脚本同时导出 runtime/validator 根；validator 输出扫描根与数量，只发现 ADR-018 定义的 `school-*` 和 `_template/*`，不递归 graphify/cache/vendor manifest。
- P1-20：XIDIAN JWC std 已使用 `index.js`、registry 对齐版本与 params、标准 fixture replay、真实 contract schema；坏日期省略，上海本地发布日期归一为 UTC。
- 集成验证：Linux Flutter `744/744`、Apple 专项 `3/3`、tools smoke `18/18`、pinned adapter replay `8/8` 通过；macOS 测试机已确认 `lib/main_apple.dart` 的 iOS 构建无报错。server smoke 为 `27/28`，唯一开放项是 pinned `school-xidian` 尚无相邻工作区中未提交的 `card.*` handler，不归入上述 P1 项的完成证据。

### 3.2 执行状态（2026-08-07 · P1-05 / P1-06 关闭，ADR-024 落地）

**P1-05（同名不同 Path Cookie）已关闭。** 根因是 `selectCookies` 按 `name` 收进 Map——
`sid=/` 与 `sid=/api` 只能活一条，origin 下发的深路径会话被根路径同名顶掉，请求带错值且无任何
报错。现按浏览器语义：命中的**全部**带上，长 Path 在前（RFC 6265 §5.4），覆盖键改为
`(name, domain, path)`。栅栏 2 未被放宽——改由「某名字只要有任一 origin cookie **在本次请求
命中**，该名下 ephemeral 全部丢弃」表达，因此 adapter 无法借不同 Path 在同名会话旁加塞。
`assembleRequest` 的同名去重也同步放开（broker 注入名仍整体压过 jar 同名条目）。

**补丁（2026-08-10 复审）：P1-05 此前只关了执行内的一半。** 首轮改动放开的是
`assembleRequest` 里 **jar 侧**的同名去重，**凭证束内部**仍按名只留第一条。于是走 B5 路线 a
收割的一束 origin cookie（`sid=API; sid=ROOT`，长 Path 在前）在注入侧被砍成 `sid=API`——
根会话**静默丢失**，与 P1-05 原始缺陷同型，只是从 jar 挪到了凭证注入这一步。收割侧的
golden（`harvest.json` 的 `p1_05_same_name_different_path_both_harvested`）本已把束形状钉成
`"sid=API; sid=ROOT"`，消费侧却把它丢了一半，**两端 golden 各自为真、合起来不成立**。
现两端 `assembleRequest` 对凭证束不再去重，新增 `assemble.json` 的
`inject_cookie_bundle_keeps_same_name_different_path_entries` /
`…_still_suppress_jar_same_name` 两例双跑钉死；栅栏 2 最外层不变（注入过的名字仍整体压掉 jar
同名条目）。安全面不变：束内容全部来自核心自己收割的 origin 区，ephemeral 永不入收割（栅栏 3）。

**残留（不在 P1-05 范围内，需要时另开 ADR）**：路线 a 的 ref 值是**路径无关**的一串，
per-cookie 的 Path 在入 Store 时就已丢失，注入时无从按请求路径再筛。当前不构成越权外发——
B1 只对命中该 ref `scope` 的 URL 注入，而收割方向要求 cookie Path 是 scope pathPrefix 的前缀，
故被注入的 URL 路径恒不浅于束内任何 cookie 的 Path。**唯一边角**是 scope 前缀不落在 `/` 边界时
（如 `https://h.edu/api*` 可匹配 `/apifoo`），浏览器不会发的 `Path=/api` cookie 仍会被带上。
要根治须走路线 b（manifest 扩 `cookieNames` 或让 ref 值携带 per-cookie Path），属契约改动
（红线 #6），需先有 ADR。

**P1-06（Secure / Max-Age / Expires / 删除）已关闭。** 四条语义按 owner 指定落地：
`Secure` 只随 https 发出（刻意不给 `http://localhost` 开浏览器式豁免）；过期不再发出、也不
再收割；收割进 Store 时带 `expiresAt`；`Max-Age=0` 与过期 `Expires` 从 jar **删除**该条。
两个刻意的取舍：① 一个 ref 的值是一束 cookie，其 `expiresAt` 取束内**最早**者——任一条死掉这
串序列化值就不再是完整会话，取 max 会把残缺凭证当有效用；② `Expires`/`Max-Age` **非法**时按
RFC 忽略该属性（退化为 session），而不是当作「立刻过期」。

**补丁（2026-08-10 复审）：客户端缺省 jar 此前没冻结时钟。** 服务端 `sandbox.ts` 把
`execNowMs` 注入 jar，捕获 / 发送选择 / 收割三处共用同一时刻；客户端
`adapter_runtime.dart` 与 `declarative_host.dart` 的 `jar ?? CookieJar()` 用的却是活钟
（`DateTime.now()`），只有 `decideHarvest` 吃冻结钟——**代码注释宣称的「执行内不自相矛盾」
在客户端并不成立**。偏差方向虽是 fail-closed，但这正是双端 golden 抓不到的一类分叉
（golden 只钉纯函数，有态部分各端自测）。现两处缺省 jar 均改为 `CookieJar(() => nowMs)`；
显式注入 jar 时仍尊重调用方自带时钟（测试确定化 seam）。回归由
`declarative_host_test.dart` 的「缺省 jar 用执行冻结钟」一例覆盖——该例用「Expires 落在
nowMs 之后、墙钟之前」判别两种钟，退回活钟必失败，非空断言。

- 跨端确定性是本批的主要风险面，故日期与 `Max-Age` 都**自己实现**、不依赖宿主：`Date.parse`
  与 `DateTime.parse` 对 RFC 850 两位年、asctime、非法日历日的处理各不相同；`Max-Age` 超长数字
  在 JS 是有限 float、在 Dart 溢出 int。两者均按 RFC 6265 §5.1.1/§5.2.2 逐 token 实现并夹取。
- golden 从 3 组扩到 6 组（新增 `parseCookieDate` / `parseMaxAge` / `parseSetCookie`），
  双端同向量双跑：server `cookie-jar` smoke `golden 90/90 + stateful 14/14`，
  client `flutter test` 全绿。`decideHarvest` / `matchCookieForSend` / `selectCookies` 的
  `nowMs` 一律**必填**，不设缺省——缺省值只会在某个调用点悄悄退化成「永不过期」。

**P0-14（ADR-024）保持开放，但已从「ADR 阻塞」推进到「代码与 Android 产物级证据齐备，待人工
签收 + 非 Android 平台补齐」。** slice 1–3 已按 landing 文档的捆绑约束同一批落地：判别器由
`kDebugMode` 换为 `kSideloadEnabled`；DEV 用独立 `applicationId` 后缀 + 启动页不可关水印；
`check_release_gate.sh` 对分发产物做符号 grep + 元数据双断言，并在 `release.yml` 中跑在**真正
要分发的那个 APK** 上。本机 Android release 实测（详见
[`docs/reference/adr_024_landing.md`](../reference/adr_024_landing.md) §4）：

| 断言 | DEPLOY | DEV |
|---|---|---|
| `applicationId` | `dev.nancunchild.elecon` | `…​.devsideload` |
| 侧载哨兵出现次数 | **0** | 3 |
| 构建元数据标记 | `DEPLOY` | `DEV-SIDELOAD` |
| release gate | 通过 | **拒绝** |

两次均为 `--release`，证实 ADR-024 §2.1 的「优化等级 ⊥ 信任 profile」解绑成立。

**slice 4 已按 2026-08-10 owner 第二轮决策重写**：渠道与信任档分离。DEV-Sideload 是全能力开发环境；
DEPLOY 永不运行未签名 / 非 official adapter。ADR-033（**已接受**，2026-08-10）在设置高级项增加
official-only 本地导入，并退役 C3；其落地前当前 DEPLOY 零入口实现与 gate 不变。

**P0-14 仍不能关闭的两点**（不得以自动验证代替）：
1. **ADR-033 会重定义 gate**：当前 Android 的“全部侧载哨兵为零”证据只覆盖旧基线；ADR-033 已接受，其落地后
   新 gate 须证明 DEPLOY 不含 devSideload grant、未签名执行与 DEV 凭证放行路径，同时证明设置内入口只汇入
   official verifier + 在线 catalog/revocation 门。单一哨兵不足以证明调用关系。
2. **非 Android 平台无产物级证明**：iOS bundle ID 后缀、macOS/Windows/Linux/OHOS 的 profile 标记与
   符号断言均未做。这些平台目前只靠护栏 1 的 fail-closed 默认成立，**没有机械复核**；
   当前仅 Android 完成 ADR-024 的产物级证明；ADR-010 的 iOS App Store 论点尚无 iOS 产物级机械证据。
3. **人工安全签收未完成**：本轨触红线 #4，AI 不得独自闭环。ADR-033 已接受但未落地，故现在只能按**旧零入口语义**签收；
   新语义须待其 §5 清单同批落地、新 gate 就位后另行签收。

**ADR-033 已于 2026-08-10 接受（打回修改后定稿）。** 全文保留完整决策过程：
① 初稿的未签名 declarative 生产侧载；② 第一轮倾向全平台 DEPLOY 零侧载；③ 定稿的双渠道方案。
定稿内容：DEV-Sideload 全能力，不再用 declarative C3 阉割开发调试；DEPLOY 在设置高级项保留本地文件
导入，但只接受 official 签名，并在每次新增/更新时强制在线刷新、验证 catalog/revocation 后才可安装。
本地导入成功后仍铸造 official grant，不新增生产低信任档。

**接受 ≠ 已落地**：截至本次记录，validator 的 C3 与 DEPLOY 零入口 gate 均未改动，实现须按 ADR-033 §5
清单同批推进（AI 不得独自闭环）。

初稿查实的 `bind`→`compute`→`inject{at:"url"}` 外泄面继续作为关键决策依据：它说明 declarative-only
不足以让未签名 adapter 进入 DEPLOY；当前方案因此把安全边界放回 official 签名、审查和吊销治理。
P0-14 的收口路径因此明确：先按旧零入口 gate 签收当前状态，待 ADR-033 §5 落地后再以新 gate 重新取证并二次签收。

> 过程中的一个实证值得留档：护栏 4b 的标记生成任务最初只声明 `outputs`、未声明 `inputs`，
> gradle 判 UP-TO-DATE，导致**首次 DEV 构建原样留下上一次 DEPLOY 的标记**——元数据自称 DEPLOY、
> 产物里却带侧载入口。是护栏 4a 的符号 grep 拦下的。这正是 ADR-024 §5.3 坚持「符号 + 元数据
> 二者并用」的价值：单靠元数据会被构建缓存击穿。已修复并双向验证。

- 本轮自动验证：server `npm run typecheck`、`npm run smoke:all`（`25/28`，三个失败项与改动前
  基线完全一致，均为外部 adapter fixture 缺失）；client `flutter analyze` 零问题；
  `flutter test` **两轮 profile** 均全绿（DEPLOY `835 passed / 11 skipped`、
  DEV `844 passed / 2 skipped`）；`check_release_gate_test.sh` 负例 4 + 正例 1 全通过。

## 4. P2：普通逻辑、解耦与可维护性

| ID | TODO | 主要位置 | 完成条件 |
|---|---|---|---|
| P2-01 | [ ] 启动页显式处理 bootstrap Future 异常并支持安全重试 | `client/lib/main.dart` | 启动失败不进入半初始化主页；损坏存储恢复路径有测试 |
| P2-02 | [x] 首页刷新 Future 等待真实请求完成并处理重复刷新代次 | `client/lib/ui/home/home_page.dart` | spinner 生命周期正确；旧请求结果不覆盖新请求 |
| P2-03 | [x] GPA 排除非正学分并处理零分母 | `client/lib/ui/home/home_page.dart` | 零学分不显示 `NaN`；单元/widget 测试覆盖 |
| P2-04 | [x] 公网 handler 捕获畸形百分号编码并返回 400 | `server/src/public/index.ts` | `/%`、非法 UTF-8 不抛出 handler；进程保持可用 |
| P2-05 | [x] 公网静态端点只允许 catalog、revocation 和合法 digest bundle 路径 | `server/src/public/index.ts`、nginx 配置 | 任意 dist 文件不自动公开；bundle 名称/大小/method 有硬限制 |
| P2-06 | [ ] 抽取共享 JSONPath tokenizer/AST，消除 dataflow 与 Masker 语义漂移 | `server/src/runtime/broker/dataflow.ts`、`response-masker.ts`、Dart 对应实现 | 安全整数、转义、错误分类共享 golden；不保留平行 parser |
| P2-07 | [ ] 抽取版本化 Credential codec 和可靠持久化队列 | H/S secure store | H/S 仅负责 DEK custody；序列化、迁移、损坏处理单源 |
| P2-08 | [ ] 使用生成契约类型替代客户端手写 manifest/credential 枚举解析 | `client/lib/catalog/schools.dart`、loader | 新 credential/schema 类型不需多处手工同步；unknown 处理明确 |
| P2-09 | [ ] 为 `AdapterService` 增加所有权清晰的 `dispose/close` | `client/lib/core/adapter_service.dart`、transport/fetcher | SessionController dispose 后 HttpClient/socket 释放；测试验证 |
| P2-10 | [x] 将 server smoke/replay/testutils 从生产源码和 build 产物分离 | `server/src/runtime/*.smoke.ts`、`tsconfig.json` | `npm run build` 不产出测试入口；测试命令保持可用 |
| P2-11 | [ ] 将所有用户可见文案迁到 ARB，并加入 UI 字面量静态门 | `client/lib/ui/`、l10n | 英文 locale 下首页、登录、安全警告无中文残留；CI 可阻止新增字面量 |
| P2-12 | [ ] 修正 Linux 支持矩阵或提供可信登录路径 | `client/lib/ui/login/login_flow.dart`、发布文档 | 若不支持认证则从正式能力矩阵排除；若支持则有平台集成测试 |
| P2-13 | [ ] 处理 OHOS pubspec 漂移，区分 probe 与正式构建清单 | `client/pubspec.ohos.yaml` | release 不会误用旧 QJS/缺依赖清单；CI 至少解析/最小编译正式清单 |
| P2-14 | [x] 统一 XJT/XJTU 命名及 adapter_tests 元数据 | `adapters_tests/` | 每目录说明 schoolId、系统、状态、敏感度和是否仍使用 |
| P2-15 | [ ] 更新 adapter SDK 为最小 `BrokerResponse`，移除鼓励 adapter 自取 token 的旧说明 | `contract/adapter-sdk/types.d.ts` | 不暴露完整 DOM Response/url；ADR-026 目标态清楚；契约改动走慢车道 |

### 4.1 执行状态（2026-08-06）

- P2-02/P2-03：刷新 Future 会等待当前最新代，刷新期间保留旧快照，迟到结果不覆盖新代；GPA 只纳入正学分并拒绝零分母/非有限结果，widget 回归通过。
- P2-04/P2-05：公网 handler 对畸形百分号和非法 UTF-8 返回 400；只服务 catalog、revocation 和 64 位小写 digest bundle，任意 dist 文件、非法名称和超 512 KiB bundle 均拒绝。
- P2-10：`tsconfig.build.json` 排除 smoke/testutils，production build 每次清空 `dist/` 并机械检查产物；全量 smoke 仍由原 `tsconfig.json` typecheck 和独立 runner 执行。
- P2-14：测试目录统一为 `XJTU/`，保留发布身份 `school-xjt`；FDU/THU/XIDIAN/XJTU 均记录 schoolId、系统、状态、敏感度和使用情况，ADR 历史证据引用已同步。
- Linux 构建：默认 lockfile 将 `jni` 从 1.0.2 更新至 1.0.3；clean 后 debug/release bundle 均构建成功，release executable 的 `ldd` 无缺失动态库。已确认 Linux 支持 S 档但不提供 H 档；为保持易用性，设置页面仅显示 S、不弹强警告。该决定只解决保护等级展示，不关闭 P2-12 的可信登录/支持矩阵决策。
- OHOS 当前不属于正式发版矩阵；`pubspec.ohos.yaml` 与 OHOS probe 保留为独立实验输入，不进入 release 构建或正式能力支持声明，P2-13 的正式清单/CI 处理仍需在未来恢复 OHOS 时另行启动。
- P2-01 涉及凭证 store bootstrap 失败状态机，按安全规则留待人工协作。P2-11 审计发现约 181 个 UI 字面量位点，需作为独立迁移批次完成，禁止用现有债务 baseline 豁免来伪装静态门。

## 5. P3：文档、CI、发布与运维

| ID | TODO | 完成条件 |
|---|---|---|
| P3-01 | [x] 建立 ADR 索引，分别记录 Decision、Landing、Security signoff、Owner、Blocker | README 不再把 Accepted 误写成 Implemented；ADR-013/023/024/026-031 状态一致 |
| P3-02 | [x] 更新或归档旧 `docs/architecture.md` 分支快照 | 不再描述旧 adapter 布局、stripEchoes 或过时 ADR 状态；明确代码事实与 ADR 约束关系 |
| P3-03 | [x] 更新 README、adapter README、testing rule 和旧 TODO | 修正模板复制命令、“越薄”两轴含义、外部 adapter fixture 路径和 ADR 状态 |
| P3-04 | [ ] 为 35 处 schema 字段补 description，并把 `--require-descriptions` 设为 CI 硬门 | codegen check 零缺失；时间、金额、窗口和缺失语义有文档 |
| P3-05 | [ ] 统一 Money 字段语义，确认哪些域允许负数 | 非负金额有 `minimum:0`；例外有领域说明；ADR-021 状态明确 |
| P3-06 | [x] 将 schema behavior golden 从 7/48 扩展到所有 registry emits/params | 覆盖嵌套 required、enum、format、null/缺失、金额、URI 和 params 边界 |
| P3-07 | [x] 明确 canonical dist，消除 `dist-full`、`dist-xidian`、bootstrap 和 release 多事实源 | **2026-09-11 关闭（§2.8）**：`client/assets/bootstrap/` 是唯一入库的签名产物，dist 树不入库（`.gitignore` `/dist-*/`），上传前 `dist:export` 反向导出；CI `bootstrap:verify` 校验 catalog ↔ bundles ↔ envelope digest 自洽 |
| P3-08 | [ ] 在发版门检查 revocation 新鲜度与 catalog/revocation sequence 单调性 | 过期或倒退时禁止 release；急性吊销流程可演练 |
| P3-09 | [x] 修复应用内版本注入 | release tag 与 About 页面一致；构建命令传入 `ELECON_VERSION` 或改用可靠平台版本源 |
| P3-10 | [x] 固定 release Flutter 版本，与普通 CI 使用同一 SDK | release 不再使用浮动 `stable`；升级单独评审 |
| P3-11 | [ ] 提交并审查 Windows/macOS 平台工程，禁止 release 临时 `flutter create` | runner、标识、entitlement 可复现且进入代码审查 |
| P3-12 | [ ] 增加依赖、许可证、SBOM、secret scanning 和 SAST 门 | npm/pub/镜像依赖均覆盖；GPL/未知许可证阻断；安全结果可追踪 |
| P3-13 | [ ] 增加 release checksum、provenance、签名和人工批准 | 各平台产物身份可验证；unsigned 工件不伪装成正式发布 |
| P3-14 | [ ] 发布正式隐私政策、数据处理说明和安全联系渠道 | App 内链接有效；说明凭证、WebView、日志、删除和第三方 SDK |
| P3-15 | [ ] 完善公网端点部署和运维 | 镜像 pin/扫描、非 root、原子发布、回滚、TLS/CDN/DNS、监控和吊销新鲜度告警齐全 |
| P3-16 | [ ] 为 campus relay 起草专项 ADR，替换“等待 ADR-003”的过时 blocker | 明确授权、协议、凭证一次性投递、状态和部署边界后才实现 |
| P3-17 | [x] 将 `widget_test.dart` 占位替换为启动、选校、登录、首页错误态集成测试 | 关键用户流程在至少 Android 模拟器形成门禁 |
| P3-18 | [x] 将 QuickJS 文案改为“共享 golden 控制已使用语义漂移” | 不再宣称两种绑定在所有行为上天然零漂移 |

### 5.1 执行状态（2026-08-07）

- P3-01/P3-02/P3-03：新增 `docs/adr/README.md` 双维状态索引；旧分支架构长文移入 `docs/archive/`，当前 `docs/architecture.md` 只保留权威入口与代码/ADR/签收优先关系；README、adapter 指南、testing rule 与旧 TODO 已同步。
- P3-09/P3-10：Android、Windows、Linux、macOS、iOS release build 均从不可变 release tag 注入 `ELECON_VERSION`；普通 CI 与 release 均固定 Flutter `3.44.1`。
- P3-06：48/48 个 schema 均有显式 valid/invalid behavior golden；registry 当前 30 个 emits + 16 个 params 引用全部覆盖，另覆盖不在 registry 的 envelope/error，包含嵌套 required、enum、format、null/缺失、Money、URI 与 params 边界。
- P3-17：占位 widget smoke 已替换为真实 `EleconApp` 启动等待、选校、登录取消与首页错误/重试流程；CI 新增 Android emulator job，以脱敏 fixture 驱动同一流程且不访问学校接口。
- P3-18：当前 README、运行时代码注释与相关 ADR 已统一为“两种 QuickJS 绑定/版本/编译配置可能不同，仅由共享 golden/canary 约束已使用语义”。
- 其余 P3 项保持开放；涉及契约、发布密钥、GitHub Environment、法律文本、正式基础设施或专项 ADR 的项目不得以文档/自动化替代人工评审与外部事实。

## 6. P4：产品与扩展性

| ID | TODO | 前置 | 完成条件 |
|---|---|---|---|
| P4-01 | [ ] 设计动态学校目录或明确受控内置目录策略 | P0/P1 承重项 | 新学校是否需要客户端发版有明确答案；涉及契约则先 ADR |
| P4-02 | [ ] 用 capability 级 `credentialRefs` 收窄 imperative 最小权限 | 独立 ADR；P0-09/P0-10 | capability 只能使用显式授权 ref；redirect/harvest 同步约束；旧 host 迁移明确 |
| P4-03 | [ ] 为课表、成绩、考试、空教室、一卡通、图书馆完成 UI 闭环 | P0-08、对应 adapter 正式签发 | loading/empty/stale/error/unsupported 四态清楚；schema 驱动而非学校硬编码 |
| P4-04 | [ ] 至少完成一个非 Xidian 学校的产品闭环 | P4-01、P4-03 | 登录、取数、schema gate、UI、fixture、签发和真机验收完整 |
| P4-05 | [ ] 明确 freshness/TTL、刷新和离线陈旧数据的用户语义 | P4-03 | UI 清楚区分最新、缓存、陈旧、失败和不支持 |
| P4-06 | [ ] 设计无凭证 telemetry/error reporting | P0-11 | 任何 URL/header/body/error 均经过永久脱敏；用户可关闭；隐私政策同步 |
| P4-07 | [ ] campus relay 在专项 ADR 接受后实现最小授权链 | P3-16 | 公网零凭证；私密数据只在校内授权环境；集成和部署安全测试完整 |

### 6.1 执行状态（2026-08-07）

- P4-03 部分推进，保持开放：在既有 `exam.list` 与 `library.loans` 契约内新增 schema 驱动的按需 UI、严格解码和空/加载/认证/错误状态；连同已有成绩、课表、空教室和一卡通，六类 typed UI 均已有客户端入口。`stale` 与显式 `unsupported` 仍依赖 P4-05 产品语义，对应 adapter 正式签发和真机验收也未完成，因此不关闭 P4-03。
- P4-01/P4-02/P4-04/P4-05/P4-06/P4-07 均受 P0/P1、独立 ADR、隐私政策、正式 adapter 或部署安全评审约束，本轮未越过前置实现。

### 6.2 契约演进待办（2026-09-11 自 `TODOList_schema_extend.md` 并入，原文已归档）

均为「有真实需求再立、先 ADR」项，不设编号、不进优先级表：

- 字段级「不支持 / 未返回 / 空 / 脱敏」四态若要在数据信封统一表达，开小 ADR 后再改 schema（与 P4-05 freshness 语义相邻）。
- 增量同步（课表变更、成绩更新、通知撤回）的版本 / 游标约定——有真实校需再立。
- 声明式过期 / 升级判据（`expiredWhenUrlMatches` 等，ADR-017 rev-2 §2.9）。
- WebVPN、多跳统一认证、验证码、会话过期的**宿主侧**能力面（adapter 不存凭证）；XIDIAN mint 闭环见 `docs/reference/xidian_mint_closed_loop_plan.md`。
- 文档：学校原始字段 → 标准字段映射指南（adapter 作者向）；契约版本升级与 vendor 兼容性检查清单固化到 `docs/rules/`。
- 已有编号的不重复列：body 凭证注入 = P1-11（ADR-029）、空调 actuator = P1-12（ADR-030）。

## 7. 推荐修改路线

### 阶段 R0：冻结与基线（1 个 PR）

目标：让后续整改可追踪，不改变运行行为。

1. 合入本清单并为 P0/P1 建立 issue/owner。
2. 建立 ADR landing status 索引骨架。
3. 固定当前测试基线、外部 adapter commit 和发布输入摘要。
4. 暂停新增 actuator、body credential、material seed 和新正式 bundle。

退出条件：每个 P0/P1 项都有 owner、目标 ADR、PR 边界和人工复核人。

### 阶段 R1：无契约止血（多个小 PR，可部分并行）

建议批次：

1. 探针/fixture/log 永久脱敏：P0-11、P0-12。
2. public URL 异常与路径 allowlist：P2-04、P2-05。
3. CI adapter 根和 discovery：P1-18、P1-19。
4. 启动、刷新、GPA、资源释放：P2-01、P2-02、P2-03、P2-09。
5. 持久化队列恢复：P1-02；登出事务 P1-03 紧随其后。

退出条件：已知直接泄漏路径关闭；普通错误不再干扰后续安全迁移；不改 contract。

### 阶段 R2：签名完整性迁移（独立安全项目）

顺序：

1. ~~修订 ADR-002/018，定义 bundle digest v2、路径规范化和兼容策略。~~（2026-09-01 就地修订，**2026-09-09 owner 签收规格**；兼容策略结论 = **无历史产物、不设兼容期**）
2. ~~先实现 TS/Dart verifier 与 golden，再实现 signer/packer。~~（**2026-09-09 两端落地、CI 全绿**，见 §2.4）
3. ~~增加 host version gate~~（**已改判：不新增**——`bundleFormat` 严格相等本身即断代拒载，见 ADR-002 §2.3 / ADR-018 §2.9.1 第 8 项；将来 masker 强制那一跳的 gate 亦复用同一机制断代到 `/3`，见 ADR-026 §2.7.1），**重新签发 bootstrap/catalog/bundle** —— 即重签仪式，**已于 2026-09-11 执行**（§2.7）。
4. ~~增加 P0-15 发布台账~~（2026-09-11 首批 5 条 complete 记录入账）和 release 防回滚 / 新鲜度检查（P3-08，仍开）。
5. 由非实现者完成人工安全复核和迁移演练。

退出条件：P0-01、P0-15 关闭；旧产物处理方式明确；只改路径必然验签失败。

### 阶段 R3：凭证隔离与存储（独立安全项目）

顺序：

1. 收窄 UI API：P0-02。
2. 落实 store scope 与旧数据迁移：P1-01。
3. 修复 Android/iOS 保护等级：P0-06、P0-07。
4. 完成登出、失败恢复、重启和真机测试：P1-02、P1-03。

退出条件：UI 无法取得明文；跨校不混用；H 档有真机证据；登出具备持久化完成语义。

### 阶段 R4：Broker 网络与交付边界（独立安全项目）

顺序：

1. 请求配额和 redirect fail-closed：P0-03、P0-05。
2. Cookie host-only、Path、过期语义：P0-04、P1-05、P1-06。
3. 原始响应头和解压实体头：P1-04、P1-07。
4. Masker 不可选装配和最终响应 policy match：P0-09、P1-09。
5. 统一 firewall 与 handle transaction：P0-10、P1-08。
6. 最后接客户端生产 schema gate：P0-08。

退出条件：任何响应进入 adapter/UI 前都经过不可绕过的安全与 schema 边界；失败、取消、并发无半提交或迟到副作用。

### 阶段 R5：契约能力补齐（严格串行）

顺序：

1. 先关闭 manifest 基础歧义：P1-13、P1-14、P1-15。
2. 再落 ADR-031 seed/material：P1-10。
3. 再落 ADR-029 body inject：P1-11。
4. 最后落 ADR-030 actuator：P1-12。
5. capability 级 `credentialRefs` 作为独立 ADR/PR：P4-02，不与上述改动捆绑。

退出条件：每一项都有 schema、validator、TS、Dart、共享 golden、host gate 和人工签收；不得一次 PR 同时改多个承重能力。

### 阶段 R6：去重、测试和文档收敛

顺序：

1. 抽取 JSONPath、Credential codec、生成类型：P2-06、P2-07、P2-08。
2. 修复模板、fixture replay 和 std adapter：P1-16、P1-17、P1-20。
3. 扩 schema golden 和 descriptions：P3-04、P3-05、P3-06。
4. 分离生产/测试源码并补 widget/integration：P2-10、P3-17。
5. 统一 README、ADR index、architecture 和旧 TODO：P3-01、P3-02、P3-03、P3-18。

退出条件：契约解析、JSONPath、Credential codec 不再有平行实现；文档能区分决策与落地状态。

### 阶段 R7：发布和运维闭环

顺序：

1. reusable release verification 与 ADR-024 gate：P0-13、P0-14。
2. canonical dist、bootstrap 和 revocation：P3-07、P3-08。
3. 版本/SDK/平台工程可复现：P3-09、P3-10、P3-11。
4. 供应链、签名、provenance、隐私：P3-12、P3-13、P3-14。
5. 公网部署、监控和回滚：P3-15。

退出条件：tag 不能绕过完整验证；发布产物、adapter bundle、bootstrap、catalog 和 revocation 均可追溯、可验证、可回滚。

### 阶段 R8：恢复产品扩展

顺序：P4-01 动态学校目录 → P4-03 现有能力 UI → P4-04 第二所学校 → P4-05 freshness → P4-07 campus relay。P4-06 telemetry 可在隐私政策完成后独立推进。

退出条件：至少两所学校形成签名 adapter、登录、取数、schema gate、UI 和真机验收的完整闭环。

## 8. PR 拆分原则

1. 一个 PR 只关闭一个安全语义或一个普通问题簇，不把签名、凭证、Masker、contract 混在一起。
2. 安全 PR 必须先列攻击/失败场景，再写实现；测试由人工实质性复核，AI 不得独自闭环。
3. 契约 PR 必须说明旧 host、旧 bundle、旧持久化数据和 rollback 行为。
4. 双端功能的完成定义包含 TS、Dart、共享 golden 和至少一个集成入口，不能只完成参考执行器。
5. 所有 fixture 必须先脱敏再入库；scanner 通过不是人工隐私复核的替代品。
6. 文档状态使用 Decision 与 Landing 两个维度，不再用单个“已接受”暗示实现完成。

## 9. 每阶段统一验证门

每个阶段至少运行：

```text
npm run lint
npm run typecheck
npm run smoke:all
flutter analyze
flutter test
```

涉及 adapter/contract/release 时另运行全量 validator、PII scanner、codegen drift、description gate、bootstrap drift 和真实 external adapters replay。涉及硬件保护、WebView 登录、URL query credential 或 actuator 时，必须增加脱敏测试账号的 Android/iOS 真机验收，真实凭证和学生数据不得写入 fixture 或日志。
