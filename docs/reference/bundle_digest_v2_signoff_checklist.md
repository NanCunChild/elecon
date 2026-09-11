# Bundle digest v2（P0-01）实现安全复核清单

> 状态：**已签收（owner NanCunChild，2026-09-11，PR #111）**。两端实现 2026-09-09 落地；规格 2026-09-09 签收；本清单覆盖**实现**的人工复核与决策 A/B/C、落地清单 #11——首轮 4 条意见（§6）修复后复签通过。重签仪式已于 2026-09-11 执行（整改清单 §2.7）。
> 🔒 触红线 #4（DEPLOY 仅运行 official 验签 adapter）。实现由 AI 辅助生成，须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环（AGENTS.md §1）。本清单签完前不得举行重签仪式——仪式是用 official 私钥为这套验签实现背书（整改清单 §2.5 阻塞 3，**已于 2026-09-11 解除**）。

实现提交：core `0ae1da4 feat(core): 落地 bundle, digest v2`（37 文件）+ 复核修正提交（见 §6）；A 仓 `737d885 feat(bundle): 切到 elecon-bundle/2`。

---

## 0. 复核方法

1. 先读规格：ADR-002 §2.3（digest 定义 + 四条不可分割纪律）→ ADR-018 §2.9.1（传输封套、**12 步验证顺序表**、签发侧全量文件承诺）。
2. 再对照代码：**以 12 步表为主线**，在 TS 与 Dart 两端各找到每一步的实现位置，确认**顺序不可交换**（尤其第 6 步验签在第 7 步 `JSON.parse` 之前）。
3. 最后对照红用例：每一类攻击都要能指到一条会变红的断言，而不是「代码看起来对」。
4. 复核时只用 `git show 0ae1da4 -- <file>` 看差异；不要在本机改动被复核的文件。

## 1. 逐文件复核

| # | 文件 | 复核要点 | ✓ |
|---|---|---|---|
| 1 | `tools/src/bundle/envelope.ts` | envelope 为清单（`files[]` = `path/size/sha256`），文件字节不内联；确定性序列化器固定键序、无多余空白；`digest = SHA-256(envelopeBytes)`；`BUNDLE_FORMAT = elecon-bundle/2`；`BUNDLE_INCLUDE`/`BUNDLE_EXCLUDE` 全量文件承诺，未列入者**拒签**而非静默跳过；路径段字符集 `[A-Za-z0-9._-]`（决策 A）；LF/NFC 为 `assertCanonical` 拒绝而非改写 | [x] |
| 2 | `tools/src/bundle/package.ts` | 唯一入口 `openBundle(rawBytes)` 收**原始字节**；传输封套仅 `envelopeB64/signature/blobs` 三字段、多余字段拒；有界 gunzip 上限未放宽；base64 **规范形**（标准字母表 + 正确填充 + re-encode 逐字相等）否则拒——`decodeCanonicalBase64`，三处（envelopeB64 / blobs / signature）都走它；算法只认 `ed25519`；**keyId → 预埋 active 锚的解析不在 TS 这一层**：`openBundle(gz, publicKey)` 由调用方传公钥，是 ADR-002 §2.3「验签层 / 加载策略分界」的刻意不对称——Dart 加载器做锚解析，TS 服务台账提取与签发侧自验，台账路径在调用侧等价钉住 keyId（`release-ledger/index.ts`）；先 digest 比对、再 Ed25519 验签（含 `contextTag ‖ 0x00`）、**然后才** parse；`bundleFormat` 严格相等；卫生闸门；blob 集合精确相等；逐文件 size 界定→解码→长度精确等于 size→sha256；身份三方一致；**不做档位门**（决策 B） | [x] |
| 3 | `tools/src/signer/index.ts` | `serializePayload` 加 `contextTag` 前缀；`computeBundleDigest` 与 `buildEnvelope` 走同一条 digest；`collectBundleFiles` 全量承诺；旧 `verifyBundleSignature(env, sig)` 形状已删除（不可再表达「先解析后验签」） | [x] |
| 4 | `tools/src/catalog/sign.ts`、`tools/src/signer/revocation.ts` | 各自 `contextTag`（`elecon.catalog/1` 等）；传输对象不变；跨域签名互不可用（对应 E7a/E7b） | [x] |
| 5 | `tools/src/bundle/sign.ts`、`tools/src/release/package.ts` | 签发流水线读显式 `IntendedTier` 入参；`release/package.ts` 产出端点 D 树（`catalog.json.gz` / `revocation.json` / `bundles/<digest>.json.gz`）。A 域三件产物 `.envelope.json` / `.unsigned.json.gz` / `.sha256` 由 **A 仓 `scripts/build-bundle.mjs`** 产出（见 #13），两者都符合 `adapter_release.md`；A 域**不另出 pretty-print 版本**（所见即所签） | [x] |
| 6 | `client/lib/core/loader/bundle.dart`、`verify.dart`、`signature.dart` | 与 #2 逐步对称：哈希**收到的那串字节**、不重排不重拼；base64 走 `decodeCanonicalBase64`（Dart 内建解码接受 URL-safe 字母表，靠 re-encode 比对补齐）；无 Unicode 规范化依赖（决策 A，靠字符集收紧）；**第 12 步档位门在此**：`tier=sideload` 在 DEPLOY 拒载（决策 B） | [x] |
| 7 | `client/lib/core/loader/loader.dart`、`bundle_cache.dart`、`signature.dart`、`catalog.dart`、`revocation.dart` | `LoadResult` 只持有一个 `VerifiedBundle`，其余为 getter（不存在可互相不一致的平行字段）；缓存按 digest 寻址；`/1` 读取路径**整体删除**、无双读 | [x] |
| 8 | `client/lib/core/adapter_launcher.dart`、`adapter_runtime.dart`、`adapter_service.dart` | 启动链只从 `VerifiedBundle` 取 entry 字节；没有任何按路径去磁盘/缓存再读一遍的旁路 | [x] |
| 9 | `contract/golden/bundle/loader.json`（21 条）+ `tools/src/bundle/make-loader-golden.ts` | 向量只给 `packedBundleBase64`，**不给**解析好的 envelope；生成器自验（期望必须是 TS 真实行为）；`non_ascii_path`、`valid_signature_sideload_tier`（带 `loaderMustRefuse`）两条钉住决策 A/B | [x] |
| 10 | `tools/src/bundle/path-binding.smoke.ts`（31 例） | 见 §2 攻击场景表，逐条对应 | [x] |
| 11 | `client/test/loader_verify_test.dart`、`loader_bundle_cache_test.dart`、`adapter_launcher_test.dart`、`utils/bundle_fixture.dart` | Dart 侧跑同一份 golden；夹具构造器不会绕过 `openBundle`；`school_manifest_test.dart` 的条件跳过只因 v1 产物尚未重签 | [x] |
| 12 | `tools/src/release-ledger/index.ts` | `ledger:extract` 对 catalog/revocation/bundle 先验签再产记录；equivocation 检查未被放宽 | [x] |
| 13 | A 仓 `scripts/build-bundle.mjs`（737d885） | 与核心 `envelope.ts` 为**独立实现**；2026-09-11 实测 5 个 adapter 的 sha256 与核心 `signer digest` **逐一相同** | [x] |

## 2. 攻击场景 ↔ 红用例

每一行都要在 `path-binding.smoke.ts` 或 golden 里找到会变红的断言：

| 场景 | 用例 | ✓ |
|---|---|---|
| 保序重命名换入口（原始缺陷） | A0/A1/A1b/A2（含两条前提断言） | [x] |
| 重复路径 | B1 | [x] |
| `..` / 内嵌 `..` / 绝对路径 / 盘符 / 反斜杠 / `./` / 空 / 尾随分隔符 / NUL / 非 NFC | C1–C10 | [x] |
| `bundleFormat` 篡改（原签名）/ 重签的 `/9` | D1/D2 | [x] |
| blob 多（夹带）/ 少 / 哈希不符 / 长度撒谎 | E1–E4 | [x] |
| 身份三方不一致（两条边） | E5/E6 | [x] |
| 无 `contextTag` / 用 catalog 域签 bundle | E7a/E7b | [x] |
| 传输封套多余字段 | E8 | [x] |
| 非规范 base64（空白 / 尾部字母表外字符 / URL-safe 字母表 / blob 内空白） | E9a–E9d（含前提断言）；golden `envelope_base64_whitespace`、`base64_urlsafe_alphabet` | [x] |
| 非 ASCII 路径两端同判 | golden `non_ascii_path` | [x] |
| 验签通过但 `tier=sideload` → 加载器拒 | golden `valid_signature_sideload_tier` | [x] |

## 3. 落地时新增的三项决策（🔒 逐项签收）

| # | 决策 | 签收 |
|---|---|---|
| A | 路径段字符集收紧为 `[A-Za-z0-9._-]`，卫生闸门不依赖 Unicode 规范化（Dart 无内建 NFC；引入第三方只是换个漂移面）。代价：adapter 内文件名不得含非 ASCII | [x] |
| B | 验签层（TS `openBundle`）不做档位门，档位门归加载器（Dart 第 12 步）。理由：`openBundle` 也服务台账提取与签发侧自验 | [x] |
| C | `*.md` 进 `BUNDLE_EXCLUDE`（= ADR-018 §2.9.1 落地清单 #11）。排除 ≠ 夹带面，被排除文件根本不进 bundle | [x] |

## 4. 复核后的自动化复跑（复核人本机）

```bash
npm run typecheck && npm run smoke:all -w tools          # 含 path-binding 26/26
cd client && bash tool/flutter_test.sh flutter test       # DEPLOY 轮
```

## 5. 签收记录

| 项 | 复核人 | 日期 | 结论 |
|---|---|---|---|
| §1 逐文件 | NanCunChild（owner） | 2026-09-11 | 通过；首轮 4 条意见（§6）修复后复签 |
| §2 攻击场景 | NanCunChild（owner） | 2026-09-11 | 通过；含复核后新增的 E9a–E9d 与 golden 两条 |
| §3 决策 A/B/C | NanCunChild（owner） | 2026-09-11 | A / B / C 均签收 |

**签收结论**：digest v2 实现（core `0ae1da4` + 修正 `a1ebdfa`）的人工安全复核完成，随 PR #111 合并（2026-09-11）。
整改清单 §2.5 阻塞 3 解除；重签仪式可在 A 仓版本 bump 后举行。

签完后：整改清单 `2026_08_review_remediation.md` §2.5 阻塞 3 解除 → 按 §2.5「仪式当天的参数」举行重签仪式 → P0-01 / P0-15 关闭。

## 6. 复核记录（2026-09-11 owner 首轮）

| # | 意见 | 处置 |
|---|---|---|
| 1 | 🔶 TS `Buffer.from(…, "base64")` 宽松，与第 3 步「非规范 base64 拒」矛盾（Dart 严格） | **已修**：两端统一 `decodeCanonicalBase64`（TS：字母表正则 + re-encode；Dart：内建严格解码 + re-encode，顺带关掉 Dart 接受 URL-safe 字母表的不对称）。红用例 E9a–E9d + golden 两条 |
| 2 | 🟡 清单 #2「keyId 只对预埋 active 锚」不是 TS 层的事 | **已改措辞**：描述为 ADR-002 §2.3 的刻意不对称 |
| 3 | 🟡 清单 #5 的 A 域产物名属 A 仓 `build-bundle.mjs` | **已改措辞** |
| 4 | ⚪ 37 文件；过期注释 `sign.ts:6`、`distribution_http.dart:8,20`、`loader.dart:33,87`、`catalog.dart:185` | **已修**（另修 `catalog.dart:217` 的 `verifyBundleSignatureWith`） |
