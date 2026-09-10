/**
 * 生成 `contract/golden/bundle/loader.json` —— **Node 签端 × Dart 加载器**的跨语言 golden 向量。
 *
 * 为何需要（ADR-002 §3 风险 5）：签名规范化规格已钉死，但**残余风险在跨平台实现一致性**。
 * Dart 侧若把 envelope 字节的取用、payload 键序、域分隔前缀、base64 解码任一处写歪，结果不是
 * "报错"，而是**验签静默失败**（好一点）或**验过了不该验的**（灾难）。故用同一份向量把两端钉死。
 *
 * **v2 的关键改动：向量给的是「线上原始字节」，不是解析好的 envelope 对象。**
 * v1 的 golden 直接把 `envelope` 作为 JSON 子对象交给 Dart，等于**替 Dart 做完了解析**——
 * 那恰好绕过了 digest v2 最重要的一条纪律：**验签先于解析**（纪律 2），以及「哈希收到的那一串
 * 字节，而不是自己重新序列化出来的字节」（纪律 1）。v2 起每个用例只给
 * `packedBundleBase64`（= 完整 `.json.gz` 传输封套），Dart 必须自己走完 1–11 步。
 * 这样两端跑的是**同一条管线的同一份输入**，而不是「TS 的输出 × Dart 的一半管线」。
 *
 * 与 `contract/golden/broker/*.json` 的差别：那些是手写的纯逻辑向量；本文件含**真实 Ed25519 签名**，
 * 手写不出来，故由本脚本生成后提交。生成是确定性的（固定测试种子 + Ed25519 本身确定性，RFC 8032），
 * 重跑本脚本应产出**逐字节相同**的 golden——若 diff 非空，说明签端行为漂移了，那正是要 CI 红的时刻。
 *
 * ⚠ 本脚本内的种子是**纯测试夹具**，不保护任何东西，与生产签名密钥（离线 YubiKey 片上生成、
 *   永不导出，ADR-002 §2.3）**无任何关系**。请勿把它当密钥管理的先例。
 *
 *   运行：cd tools && npx tsx src/bundle/make-loader-golden.ts
 */

import { createPrivateKey, createPublicKey, sign as edSign, type KeyObject } from "node:crypto";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import {
  CONTEXT_TAG_BUNDLE,
  CONTEXT_TAG_CATALOG,
  type SignatureFile,
  serializePayload,
  type TrustTier,
  withContext,
} from "../signer/index.js";
import {
  type BlobTable,
  BUNDLE_FORMAT,
  type BuiltBundle,
  type BundleEnvelope,
  type EnvelopeFileDescriptor,
  envelopeDigest,
  serializeEnvelope,
  sha256Hex,
} from "./envelope.js";
import { packBundle } from "./package.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

// ---- 测试密钥（固定种子 → 确定性 golden；**非生产密钥**，见文件头警告） ----

const TEST_ONLY_SEED = Buffer.from("elecon-loader-golden-test-seed!!", "utf-8"); // 恰 32 字节
if (TEST_ONLY_SEED.length !== 32) throw new Error(`种子须 32 字节，得 ${TEST_ONLY_SEED.length}`);

// Ed25519 PKCS#8 前缀（RFC 8410）：SEQUENCE{ INTEGER 0, AlgId{1.3.101.112}, OCTETSTRING{ OCTETSTRING{seed} } }
const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
function keyFromSeed(seed: Buffer): KeyObject {
  return createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519_PREFIX, seed]),
    format: "der",
    type: "pkcs8",
  });
}
function rawPubOf(priv: KeyObject): Buffer {
  return createPublicKey(priv).export({ format: "der", type: "spki" }).subarray(-32);
}

const privateKey = keyFromSeed(TEST_ONLY_SEED);
const rawPub = rawPubOf(privateKey);

const otherPriv = keyFromSeed(Buffer.from("elecon-loader-golden-OTHER-seed!", "utf-8"));
const otherRawPub = rawPubOf(otherPriv);

// ---- 合成 bundle（**自包含**：不依赖任何真实 adapter，免其内容变动打断 golden） ----

const ID = "school-golden";
const VERSION = "1.2.3";

function manifestJson(adapterId = ID, adapterVersion = VERSION): string {
  return `${JSON.stringify(
    {
      schemaVersion: "1.0",
      adapterId,
      adapterVersion,
      capabilities: ["notice.list"],
      runtime: { entry: "index.js", stdlibMin: "1.0.0" },
    },
    null,
    2,
  )}\n`;
}

/**
 * 合成一份 bundle。**刻意不走 `buildEnvelope`**：那条路会做卫生闸门与全量承诺检查，而 golden
 * 正需要构造出「签发侧本不该产出、但攻击者可以拼出来」的畸形输入，用以验证 **Dart 收端自己**
 * 拦得住——而不是依赖「Node 签端应该不会那么干」。
 *
 * `entries` 的 value 是 `string | Buffer`：前者按 UTF-8 编码（钉死跨语言 UTF-8 一致），
 * 后者原样（钉死二进制 blob 的 base64 往返）。
 */
function synth(
  entries: ReadonlyArray<readonly [path: string, content: string | Buffer]>,
  opts: { adapterId?: string; adapterVersion?: string; bundleFormat?: string; sort?: boolean } = {},
): BuiltBundle {
  const blobs: BlobTable = {};
  const files: EnvelopeFileDescriptor[] = entries.map(([path, content]) => {
    const raw = typeof content === "string" ? Buffer.from(content, "utf-8") : content;
    const hash = sha256Hex(raw);
    blobs[hash] = raw;
    return { path, size: raw.length, sha256: hash };
  });
  if (opts.sort !== false) files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const envelope: BundleEnvelope = {
    bundleFormat: opts.bundleFormat ?? BUNDLE_FORMAT,
    adapterId: opts.adapterId ?? ID,
    adapterVersion: opts.adapterVersion ?? VERSION,
    files,
  };
  return { envelope, bytes: serializeEnvelope(envelope), blobs };
}

/** 用测试私钥对一份 built 出签（身份/档位可覆写，用于构造身份混淆与档位负例）。 */
function sign(
  built: BuiltBundle,
  opts: { adapterId?: string; adapterVersion?: string; tier?: TrustTier; key?: KeyObject } = {},
): SignatureFile {
  const adapterId = opts.adapterId ?? built.envelope.adapterId;
  const adapterVersion = opts.adapterVersion ?? built.envelope.adapterVersion;
  const tier = opts.tier ?? "official";
  const digest = envelopeDigest(built.bytes);
  const payload = serializePayload({ adapterId, adapterVersion, tier, digest });
  return {
    adapterId,
    adapterVersion,
    tier,
    digest,
    signature: edSign(null, payload, opts.key ?? privateKey).toString("base64"),
    keyId: "golden-test-key",
    algorithm: "ed25519",
  };
}

// 正例 bundle。刻意混入：① 非 ASCII 文本（钉死 UTF-8 字节一致）；② 真二进制资产（钉死
// blob 的 base64 解码分支）；③ 两个**内容相同**的文件（钉死 blob 按内容寻址、一份 blob 两处引用）。
const SAME = "shared\n";
const good = synth([
  ["index.js", 'export const capabilities = ["notice.list"];\n'],
  ["assets/icon.bin", Buffer.from([0x00, 0x01, 0xff, 0xfe])],
  ["manifest.json", manifestJson()],
  ["notes.txt", "中文与 emoji 🔒：钉死 UTF-8 字节一致\n"],
  ["a.txt", SAME],
  ["b.txt", SAME], // 与 a.txt 同内容 → 共用同一个 blob
]);
const goodSig = sign(good);
const digest = envelopeDigest(good.bytes);

// ---- 用例构造 ----

interface GoldenCase {
  name: string;
  _why: string;
  packedBundleBase64: string;
  publicKeyRawHex: string;
  expect:
    | {
        ok: true;
        tier: string;
        digest: string;
        /**
         * 验签**成立**，但加载器仍必须拒绝加载。
         *
         * 验签回答的是「这份字节是谁、以什么档位签的」；**要不要加载**是另一层裁定
         * （ADR-002 §2.6）。两者混在一起会让 `openBundle` 同时背负「密码学事实」与
         * 「信任策略」，而台账/自验这类**非加载**调用方恰恰需要前者不带后者。
         */
        loaderMustRefuse?: true;
      }
    | { ok: false; reasonContains: string };
}

const cases: GoldenCase[] = [];

function push(
  name: string,
  why: string,
  packed: Buffer,
  expect: GoldenCase["expect"],
  publicKeyRawHex = rawPub.toString("hex"),
): void {
  cases.push({ name, _why: why, packedBundleBase64: packed.toString("base64"), publicKeyRawHex, expect });
}

// 1. 正例
push(
  "valid_official",
  "正例：走完 1–11 步 → 裁定 official。含非 ASCII 文本、真二进制 blob、两处引用同一 blob。",
  packBundle(good.bytes, goodSig, good.blobs),
  { ok: true, tier: "official", digest },
);

// 2. 篡改 envelope 字节 → 第 5 步（digest）就拒，**早于验签**
{
  const tampered = Buffer.from(good.bytes.toString("utf-8").replace('"index.js"', '"index.jZ"'), "utf-8");
  push(
    "tampered_envelope_bytes",
    "改 envelope 里的一个路径字符 → digest 不符。**必须在验签之前**被拒（第 5 步），" +
      "这是「验的字节 = 要用的字节」的落实。",
    packBundle(tampered, goodSig, good.blobs),
    { ok: false, reasonContains: "digest" },
  );
}

// 3. 篡改 blob 内容（等长）→ 第 10 步
{
  const desc = good.envelope.files.find((f) => f.path === "index.js")!;
  const orig = good.blobs[desc.sha256]!;
  const swapped = Buffer.from(orig);
  swapped[0] = swapped[0]! ^ 0x01;
  push(
    "tampered_blob_content",
    "blob 键不变、内容翻一个 bit（等长）→ 第 10 步内容寻址抓到。等长是为了与 size 检查分开。",
    packBundle(good.bytes, goodSig, { ...good.blobs, [desc.sha256]: swapped }),
    { ok: false, reasonContains: "哈希" },
  );
}

// 4. 错公钥
push(
  "wrong_public_key",
  "非预埋 pin 公钥签的 → 第 6 步拒。",
  packBundle(good.bytes, goodSig, good.blobs),
  { ok: false, reasonContains: "验签" },
  otherRawPub.toString("hex"),
);

// 5. 身份混淆：签名载荷身份 ≠ envelope 顶层（digest 与 Ed25519 皆真）
push(
  "identity_confusion_signature",
  "🔒 ADR-002 §2.2：digest 真、Ed25519 真，但签名载荷身份 ≠ envelope 顶层。" +
    "运行时用的是 bundle 内 manifest（定 allow/credentials），不核对即身份混淆 → 必须拒。",
  packBundle(good.bytes, sign(good, { adapterId: "school-evil", adapterVersion: "9.9.9" }), good.blobs),
  { ok: false, reasonContains: "身份" },
);

// 6. envelope 顶层身份 ≠ manifest.json 内容
{
  const mismatch = synth(
    [
      ["index.js", "x\n"],
      ["manifest.json", manifestJson()],
    ],
    {
      adapterId: "school-other",
    },
  );
  push(
    "identity_confusion_manifest",
    "envelope 顶层身份是**核对副本**，manifest.json 才是权威。两者分叉必须拒，" +
      "绝不可「就近取一个」——取顶层等于让身份脱离被签内容自由声明。",
    packBundle(mismatch.bytes, sign(mismatch), mismatch.blobs),
    { ok: false, reasonContains: "身份" },
  );
}

// 7. 算法降级
push(
  "unsupported_algorithm",
  "算法降级：非 ed25519 一律拒，不做任何回退/协商（第 4 步）。",
  packBundle(good.bytes, { ...goodSig, algorithm: "rsa-sha256" as never }, good.blobs),
  { ok: false, reasonContains: "算法" },
);

// 8. 无 manifest.json（digest 与签名都真）
{
  const noManifest = synth([
    ["index.js", "x\n"],
    ["notes.txt", "y\n"],
  ]);
  push(
    "missing_manifest",
    "🔒 envelope 无 manifest.json，但 digest 与 Ed25519 **都真**（对这份 envelope 而言）——" +
      "故会一路走到身份核对。无权威身份来源时必须拒，**不得**退化为采信签名自报的 adapterId。" +
      "签端本就拒签这种 envelope，此为验端的纵深防御。",
    packBundle(noManifest.bytes, sign(noManifest), noManifest.blobs),
    { ok: false, reasonContains: "manifest" },
  );
}

// 9. tier=sideload（签名对同一 envelope、同一密钥**有效**）
//
// **这条用例的期望在 v2 被改判**，且改判本身就是要钉住的语义：
//   `openBundle` 是**密码学裁定**——它回答「这串字节是谁签的、签成什么档位」，档位是它
//   *产出*的已验证事实，不是它的准入条件。故它 `ok:true` 并返回 `tier: "sideload"`。
//   「只加载 official」是**信任策略**，属于加载器（ADR-002 §2.6 / 红线 #4），在此之上一层。
//
// v1 的 golden 把两者混在 `verifyBundleSignature` 里，代价是台账提取、签发侧自验这些
// **非加载**调用方也被迫接受一个会拒 sideload 的 API。分开之后，本用例同时钉住两件事：
//   ① 验签层**不得**擅自拒——否则非加载调用方拿不到已验签的 sideload 事实；
//   ② 加载器层**必须**拒——否则一份远程签名就能自称 sideload 进 dev 档（ADR-002 §2.5）。
push(
  "valid_signature_sideload_tier",
  "🔒 tier=sideload 但签名对同一 envelope、同一密钥有效：验签层应 **ok + tier=sideload**（密码学事实），" +
    "加载器层**必须拒**（loaderMustRefuse，红线 #4 / ADR-002 §2.5 —— 远程签名不能自称 sideload 进 dev 档）。" +
    "与 wrong_public_key 的区别：那个在验签步就拒、根本测不到档位语义。",
  packBundle(good.bytes, sign(good, { tier: "sideload" }), good.blobs),
  { ok: true, tier: "sideload", digest, loaderMustRefuse: true },
);

// 10. blob 表多一个（夹带通道）—— v2 唯一新增的、可以搞砸的不变量
{
  const extra = Buffer.from("夹带的第二段代码\n", "utf-8");
  push(
    "extra_blob_smuggling",
    "★ blob 表多一个未被任何 descriptor 引用的条目。少一个会被逐文件校验抓到，**多一个不会**——" +
      "descriptor 全都对得上，多出来的只是「没人引用」。不显式拒即完美夹带通道：签名照过、" +
      "审查看不见（审查看的是清单），而任何按 sha256 取 blob 的消费方都能取到它。",
    packBundle(good.bytes, goodSig, { ...good.blobs, [sha256Hex(extra)]: extra }),
    { ok: false, reasonContains: "多出" },
  );
}

// 11. blob 表少一个
{
  const desc = good.envelope.files.find((f) => f.path === "notes.txt")!;
  const missing = { ...good.blobs };
  delete missing[desc.sha256];
  push(
    "missing_blob",
    "descriptor 引用了不存在的 blob → 清单承诺的文件没到货，必须拒（第 9 步）。",
    packBundle(good.bytes, goodSig, missing),
    { ok: false, reasonContains: "缺" },
  );
}

// 12. descriptor.size 撒谎（哈希仍命中）
{
  const lying = synth([
    ["index.js", "x\n"],
    ["manifest.json", manifestJson()],
  ]);
  lying.envelope.files.find((f) => f.path === "index.js")!.size += 4096;
  const rebuilt: BuiltBundle = {
    envelope: lying.envelope,
    bytes: serializeEnvelope(lying.envelope),
    blobs: lying.blobs,
  };
  push(
    "descriptor_size_lies",
    "descriptor 说 N+4096 字节、实际 N（哈希仍命中）→ 必须拒。**先按 size 界定再解码**是 TUF " +
      "携带 length 的同一理由：不能等哈希算完才发现来的是 12 MiB。",
    packBundle(rebuilt.bytes, sign(rebuilt), rebuilt.blobs),
    { ok: false, reasonContains: "长度" },
  );
}

// 13. 路径穿越（卫生闸门在验签**之后**）
{
  const evil = synth([
    ["../../evil.js", "pwn\n"],
    ["index.js", "x\n"],
    ["manifest.json", manifestJson()],
  ]);
  push(
    "path_traversal",
    "签名只证明发布者确实想要这些路径，**不证明路径安全**——哈希再多字节也不会让 `../../` 变安全。" +
      "闸门位置：验签之后、使用之前（纪律 3）。",
    packBundle(evil.bytes, sign(evil), evil.blobs),
    { ok: false, reasonContains: "路径" },
  );
}

// 13b. 非 ASCII 路径段（字符集白名单）
//
// 这条**专门钉跨语言一致性**：TS 有 `String.normalize("NFC")`，Dart 没有。若靠 NFC 检查来防
// 非规范化路径，两端就会对同一份 bundle 给出不同判定（且 Dart 方向是 fail-open）。v2 改为
// 两端共用同一个 ASCII 字符集白名单，本用例即其跨语言证据。
{
  const nonAscii = synth([
    ["assets/图标.svg", "<svg/>\n"],
    ["index.js", "x\n"],
    ["manifest.json", manifestJson()],
  ]);
  push(
    "non_ascii_path",
    "路径段含 [A-Za-z0-9._-] 之外的字符 → 两端必须**同样**拒。Dart 无内建 NFC，故卫生闸门" +
      "不依赖 Unicode 规范化，而是收紧字符集从源头消灭该问题（ADR-002 §3 风险 5）。",
    packBundle(nonAscii.bytes, sign(nonAscii), nonAscii.blobs),
    { ok: false, reasonContains: "之外的字符" },
  );
}

// 14. 重复路径（跨语言解析差分）
{
  const dup = synth(
    [
      ["index.js", "first\n"],
      ["index.js", "second\n"],
      ["manifest.json", manifestJson()],
    ],
    { sort: false },
  );
  push(
    "duplicate_path",
    "同名条目：TS `Array.sort` 稳定而 Dart `List.sort` **不保证稳定**，且任一端改用 Map 即成 " +
      "last-wins 解析差分（ADR-002 §3 风险 5）。必须整体拒，而非依赖「大家都取第一条」。",
    packBundle(dup.bytes, sign(dup), dup.blobs),
    { ok: false, reasonContains: "重复路径" },
  );
}

// 15. bundleFormat 严格相等（digest 与签名皆真）
{
  const v9 = synth(
    [
      ["index.js", "x\n"],
      ["manifest.json", manifestJson()],
    ],
    {
      bundleFormat: "elecon-bundle/9",
    },
  );
  push(
    "unknown_bundle_format",
    "重签的 elecon-bundle/9：digest 与签名全真，只有格式标识不同 → 必须严格相等地拒。" +
      "宽容（如「以 elecon-bundle/ 开头即可」）会在 v3 出现时变成降级面（纪律 6）。",
    packBundle(v9.bytes, sign(v9), v9.blobs),
    { ok: false, reasonContains: "bundleFormat" },
  );
}

// 16. 传输封套多余字段（验签前解析面最小化）
{
  const wire = {
    envelopeB64: good.bytes.toString("base64"),
    signature: goodSig,
    blobs: Object.fromEntries(Object.entries(good.blobs).map(([h, b]) => [h, b.toString("base64")])),
    extra: "验签前的自由输入",
  };
  push(
    "wire_extra_field",
    "封套是**验签之前唯一被解析的东西**，解析面必须最小：三字段严格封闭。任何「多余字段先忽略着」" +
      "的宽容都是攻击者在验签前可以自由投喂的输入（第 2 步）。",
    gzipSync(Buffer.from(JSON.stringify(wire), "utf-8")),
    { ok: false, reasonContains: "多余字段" },
  );
}

// 17. 无域分隔前缀的签名（v2 之前的签法）
{
  const bare = serializePayload({
    adapterId: ID,
    adapterVersion: VERSION,
    tier: "official",
    digest,
  }).subarray(CONTEXT_TAG_BUNDLE.length + 1);
  push(
    "signature_without_context_tag",
    "v2 之前 bundle 载荷 / catalog / revocation 三者只靠「JSON 形状恰好互不满足对方 schema」**偶然**" +
      "隔开。域分隔落地后，不带 `elecon.bundle-payload/2` 前缀的签名必须验不过（第 6 步）。",
    packBundle(
      good.bytes,
      { ...goodSig, signature: edSign(null, bare, privateKey).toString("base64") },
      good.blobs,
    ),
    { ok: false, reasonContains: "验签" },
  );
}

// 18. 用 catalog 域签的签名
{
  const bare = serializePayload({
    adapterId: ID,
    adapterVersion: VERSION,
    tier: "official",
    digest,
  }).subarray(CONTEXT_TAG_BUNDLE.length + 1);
  push(
    "signature_wrong_context_domain",
    "同一把密钥、同一份正文，只是签在 `elecon.catalog/1` 域下 → 在 bundle 这里必须拒。" +
      "这才是「域分隔」的实义：跨协议重放不成立。",
    packBundle(
      good.bytes,
      {
        ...goodSig,
        signature: edSign(null, withContext(CONTEXT_TAG_CATALOG, bare), privateKey).toString("base64"),
      },
      good.blobs,
    ),
    { ok: false, reasonContains: "验签" },
  );
}

// 19. / 20. 非规范 base64（第 3 步）——两端必须同判
//     Buffer.from(s,"base64") 宽松（忽略空白、接受 URL-safe 字母表）；Dart base64.decode 拒空白但
//     **接受 URL-safe**。内容寻址让这没有信任面影响，但「同一份封套两端不同判」正是风险 5 的形状。
{
  const envB64 = good.bytes.toString("base64");
  const blobsB64 = Object.fromEntries(Object.entries(good.blobs).map(([h, b]) => [h, b.toString("base64")]));
  const wireOf = (e: string, b: Record<string, string>) =>
    gzipSync(Buffer.from(JSON.stringify({ envelopeB64: e, signature: goodSig, blobs: b }), "utf-8"));
  push(
    "envelope_base64_whitespace",
    "envelopeB64 内嵌空白：宽松解码仍得到同一份被签字节，但规范形要求 re-encode 逐字等于原串（第 3 步）。",
    wireOf(`${envB64.slice(0, 8)}\n${envB64.slice(8)}`, blobsB64),
    { ok: false, reasonContains: "base64" },
  );
  // URL-safe 变体只对含 `+`/`/` 的串有意义；在 envelope 与 blobs 里找一个，找不到即生成器自身失效。
  const toUrlSafe = (x: string) => x.replace(/\+/g, "-").replace(/\//g, "_");
  let urlSafeWire: Buffer | null = null;
  if (/[+/]/.test(envB64)) {
    urlSafeWire = wireOf(toUrlSafe(envB64), blobsB64);
  } else {
    const hit = Object.entries(blobsB64).find(([, b]) => /[+/]/.test(b));
    if (hit) urlSafeWire = wireOf(envB64, { ...blobsB64, [hit[0]]: toUrlSafe(hit[1]) });
  }
  if (!urlSafeWire)
    throw new Error("golden 生成器：envelope 与 blobs 的 base64 均不含 +// ，URL-safe 用例无法表达");
  push(
    "base64_urlsafe_alphabet",
    "URL-safe 字母表（`-`/`_`）：Node 与 Dart 的宽松解码都接受，但传输封套只认标准字母表；" +
      "Dart 侧靠 re-encode 比对拒，TS 侧靠字母表正则拒——两端同判。",
    urlSafeWire,
    { ok: false, reasonContains: "base64" },
  );
}

// ---- 自验：golden 里的每条期望都必须是 TS 侧**真实产生**的行为 ----
//
// 没有这一步，golden 就只是「我以为会这样」的一份手写清单：写错了 Dart 会被钉到错误的行为上，
// 而 TS 侧无人察觉。跑一遍 openBundle 把期望与实际对齐——本脚本从此只能生成**真的**向量。

{
  const { createPublicKey: mkPub } = await import("node:crypto");
  const { openBundle } = await import("./package.js");
  const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
  const pubOf = (rawHex: string): KeyObject =>
    mkPub({
      key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(rawHex, "hex")]),
      format: "der",
      type: "spki",
    });

  for (const c of cases) {
    const r = openBundle(Buffer.from(c.packedBundleBase64, "base64"), pubOf(c.publicKeyRawHex));
    if (c.expect.ok) {
      if (!r.ok) throw new Error(`golden 用例 ${c.name} 期望通过，实际拒：${r.reason}`);
      if (r.value.tier !== c.expect.tier) {
        throw new Error(`golden 用例 ${c.name} 档位应为 ${c.expect.tier}，实际 ${r.value.tier}`);
      }
      if (c.expect.digest !== envelopeDigest(r.value.envelopeBytes)) {
        throw new Error(`golden 用例 ${c.name} digest 不符`);
      }
    } else {
      if (r.ok) throw new Error(`golden 用例 ${c.name} 期望拒绝，实际通过 —— 这是一个真实的安全回退`);
      if (!r.reason.includes(c.expect.reasonContains)) {
        throw new Error(`golden 用例 ${c.name} 期望原因含「${c.expect.reasonContains}」，实际：${r.reason}`);
      }
    }
  }
  console.log(`  ✓ 自验：${cases.length} 条向量的期望均与 TS 侧实际行为一致`);
}

// ---- 输出 ----

const golden = {
  _doc:
    "Node 签端 × Dart 🔒 加载器的跨语言 golden（digest v2，ADR-018 §2.9.1）。落实 ADR-002 §3 风险 5：" +
    "签名规范化规格已钉死，残余风险在跨平台实现一致性。**每个用例只给 `packedBundleBase64`（完整 " +
    "`.json.gz` 传输封套）**，两端各自走完 §2.9.1 的 1–11 步——刻意不给解析好的 envelope 对象，" +
    "否则就替 Dart 做完了解析，恰好绕过「验签先于解析」与「哈希收到的那串字节」两条纪律。" +
    "**改动本文件触碰红线 #4 验签路径，须人工 + 安全清单复核。**",
  _generator: "tools/src/bundle/make-loader-golden.ts（确定性；重跑应产出逐字节相同的文件）",
  _keyNote:
    "publicKeyRawHex 是**测试**公钥（固定种子派生，Ed25519 确定性）。与生产签名密钥（离线 YubiKey " +
    "片上生成、永不导出）无关，**绝不可**出现在客户端预埋 pin 集合里——预埋集见 " +
    "client/lib/core/loader/trust_anchors.dart。",
  _reasonContainsNote:
    "`reasonContains` 是**中文子串**匹配，钉的是「拒在哪一步」而非具体措辞。两端的失败原因需含该子串；" +
    "改措辞时请同步两端与本 golden——这正是它该拦住的漂移。",

  bundleFormat: BUNDLE_FORMAT,
  publicKeyRawHex: rawPub.toString("hex"),
  otherPublicKeyRawHex: otherRawPub.toString("hex"),

  /** 钉死 serializePayload 的**逐字节**产物（含域分隔前缀；hex 以免 NUL 在 JSON 里失真）。 */
  expectedPayloadHex: serializePayload({
    adapterId: ID,
    adapterVersion: VERSION,
    tier: "official",
    digest,
  }).toString("hex"),
  contextTagBundle: CONTEXT_TAG_BUNDLE,

  /** 钉死 envelope 的**逐字节**序列化（键序 + 无空白 + 文件字典序）与其 digest。 */
  expectedEnvelopeUtf8: good.bytes.toString("utf-8"),
  expectedDigest: digest,

  cases,
};

const out = `${repoRoot}contract/golden/bundle/loader.json`;
writeFileSync(out, `${JSON.stringify(golden, null, 2)}\n`);
console.log(`已写出 ${out}`);
console.log(`  digest : ${digest}`);
console.log(`  pubkey : ${rawPub.toString("hex")}`);
console.log(`  cases  : ${cases.length}`);
