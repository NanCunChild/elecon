/**
 * 生成 `contract/golden/bundle/loader.json` —— **Node 签端 × Dart 加载器**的跨语言 golden 向量。
 *
 * 为何需要（ADR-002 §3 风险 5）：签名规范化规格已钉死，但**残余风险在跨平台实现一致性**。
 * Dart 侧若把 digest 拼接顺序、payload 键序、base64/utf-8 解码任一处写歪，结果不是"报错"，
 * 而是**验签静默失败**（好一点）或**验过了不该验的**（灾难）。故用同一份向量把两端钉死。
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

import { createPrivateKey, createPublicKey, sign as edSign } from "node:crypto";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { type SignatureFile, serializePayload } from "../signer/index.js";
import { BUNDLE_FORMAT, type BundleEnvelope, envelopeDigest } from "./envelope.js";
import { packBundle } from "./package.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

// ---- 测试密钥（固定种子 → 确定性 golden；**非生产密钥**，见文件头警告） ----

const TEST_ONLY_SEED = Buffer.from("elecon-loader-golden-test-seed!!", "utf-8"); // 恰 32 字节
if (TEST_ONLY_SEED.length !== 32) throw new Error(`种子须 32 字节，得 ${TEST_ONLY_SEED.length}`);

// Ed25519 PKCS#8 前缀（RFC 8410）：SEQUENCE{ INTEGER 0, AlgId{1.3.101.112}, OCTETSTRING{ OCTETSTRING{seed} } }
const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const privateKey = createPrivateKey({
  key: Buffer.concat([PKCS8_ED25519_PREFIX, TEST_ONLY_SEED]),
  format: "der",
  type: "pkcs8",
});
const publicKey = createPublicKey(privateKey);
const rawPub = publicKey.export({ format: "der", type: "spki" }).subarray(-32);

// ---- 合成 envelope（**自包含**：不依赖任何真实 adapter，免其内容变动打断 golden） ----

const manifest = {
  schemaVersion: "1.0",
  adapterId: "school-golden",
  adapterVersion: "1.2.3",
  capabilities: ["notice.list"],
  runtime: { stdlibMin: "1.0.0" },
};

// 刻意混入：① 非 ASCII（钉死 UTF-8 编码一致）；② base64 二进制文件（钉死解码分支）；
// ③ 文件**故意不按字典序**列出（钉死 envelopeDigest 内部会排序，而非依赖输入顺序）。
const envelope: BundleEnvelope = {
  bundleFormat: BUNDLE_FORMAT,
  files: [
    { path: "index.js", encoding: "utf-8", content: 'export const capabilities = ["notice.list"];\n' },
    {
      path: "assets/icon.bin",
      encoding: "base64",
      content: Buffer.from([0x00, 0x01, 0xff, 0xfe]).toString("base64"),
    },
    { path: "manifest.json", encoding: "utf-8", content: `${JSON.stringify(manifest, null, 2)}\n` },
    { path: "notes.txt", encoding: "utf-8", content: "中文与 emoji 🔒：钉死 UTF-8 字节一致\n" },
  ],
};

const digest = envelopeDigest(envelope);
const payload = serializePayload({
  adapterId: manifest.adapterId,
  adapterVersion: manifest.adapterVersion,
  tier: "official",
  digest,
});
const signature: SignatureFile = {
  adapterId: manifest.adapterId,
  adapterVersion: manifest.adapterVersion,
  tier: "official",
  digest,
  signature: edSign(null, payload, privateKey).toString("base64"),
  keyId: "golden-test-key",
  algorithm: "ed25519",
};

// 另一把密钥（用于"错公钥应拒"的负例）
const otherPriv = createPrivateKey({
  key: Buffer.concat([
    PKCS8_ED25519_PREFIX,
    Buffer.from("elecon-loader-golden-OTHER-seed!!".slice(0, 32), "utf-8"),
  ]),
  format: "der",
  type: "pkcs8",
});
const otherRawPub = createPublicKey(otherPriv).export({ format: "der", type: "spki" }).subarray(-32);

// 身份混淆负例：真私钥签、digest 真、但载荷身份 ≠ envelope 内 manifest（ADR-002 §2.2）
const forgedIdentityPayload = serializePayload({
  adapterId: "school-evil",
  adapterVersion: "9.9.9",
  tier: "official",
  digest,
});
const forgedIdentity: SignatureFile = {
  adapterId: "school-evil",
  adapterVersion: "9.9.9",
  tier: "official",
  digest,
  signature: edSign(null, forgedIdentityPayload, privateKey).toString("base64"),
  keyId: "golden-test-key",
  algorithm: "ed25519",
};

// 篡改内容负例：改一个字节 → digest 不再匹配
const tamperedEnvelope: BundleEnvelope = {
  ...envelope,
  files: envelope.files.map((f) =>
    f.path === "index.js" ? { ...f, content: `${f.content}// tampered\n` } : f,
  ),
};

// 无 manifest 负例：**digest 与签名都真**（对这份无 manifest 的 envelope 而言），
// 只是 envelope 里没有 manifest.json。若只删文件而不重签，digest 检查会先拒——那测不到
// 身份这一步。这里重新签，让它一路走到身份核对：验证加载器**不会**在无权威身份来源时
// 退化为采信签名自报的 adapterId（那正是 ADR-002 §2.2 要防的）。
// 现实来源：签名管线自身的 bug（`signEnvelope` 本身会拒签无 manifest 的 envelope，
// 故这是纵深防御——验端不因签端"应该不会"而放松）。
const noManifestEnvelope: BundleEnvelope = {
  ...envelope,
  files: envelope.files.filter((f) => f.path !== "manifest.json"),
};
const noManifestDigest = envelopeDigest(noManifestEnvelope);
const noManifestSig: SignatureFile = {
  adapterId: manifest.adapterId,
  adapterVersion: manifest.adapterVersion,
  tier: "official",
  digest: noManifestDigest,
  signature: edSign(
    null,
    serializePayload({
      adapterId: manifest.adapterId,
      adapterVersion: manifest.adapterVersion,
      tier: "official",
      digest: noManifestDigest,
    }),
    privateKey,
  ).toString("base64"),
  keyId: "golden-test-key",
  algorithm: "ed25519",
};

// tier=sideload 负例：**对同一 envelope、用同一把测试密钥、把 tier 签成 sideload**。
// 关键：payload 里的 tier 变了 → 必须重新签，否则 Ed25519 在第 6 步就拒（测不到档位步）。
// 这样它能一路通过 算法/格式/digest/身份/公钥/Ed25519，**只在第 7 步（档位）被拒**——
// 从而真正验证「验签只裁定 official，sideload 不由远程签名放行」的语义（ADR-002 §2.5）。
const sideloadSig: SignatureFile = {
  adapterId: manifest.adapterId,
  adapterVersion: manifest.adapterVersion,
  tier: "sideload",
  digest,
  signature: edSign(
    null,
    serializePayload({
      adapterId: manifest.adapterId,
      adapterVersion: manifest.adapterVersion,
      tier: "sideload",
      digest,
    }),
    privateKey,
  ).toString("base64"),
  keyId: "golden-test-key",
  algorithm: "ed25519",
};

const golden = {
  _doc:
    "Node 签端 × Dart 🔒 加载器的跨语言验签 golden。落实 ADR-002 §3 风险 5（规范化规格已钉死，残余风险在跨平台实现一致性）。" +
    "两端照同一向量跑：envelopeDigest 的双层 SHA-256 与排序、serializePayload 的固定键序、utf-8/base64 解码、Ed25519 验签、" +
    "以及 ADR-002 §2.2 的身份核对。任一处漂移即 CI 红。**改动本文件触碰红线 #4 验签路径，须人工 + 安全清单复核。**",
  _generator: "tools/src/bundle/make-loader-golden.ts（确定性；重跑应产出逐字节相同的文件）",
  _keyNote:
    "publicKeyRawHex 是**测试**公钥（固定种子派生，Ed25519 确定性）。与生产签名密钥（离线 YubiKey 片上生成、永不导出）无关，" +
    "**绝不可**出现在客户端预埋 pin 集合里——预埋集见 client/lib/core/loader/trust_anchors.dart。",

  publicKeyRawHex: rawPub.toString("hex"),
  otherPublicKeyRawHex: otherRawPub.toString("hex"),

  /** 钉死 serializePayload 的**逐字节**产物（键序 adapterId/adapterVersion/digest/tier）。 */
  expectedPayloadUtf8: payload.toString("utf-8"),
  expectedDigest: digest,

  /** gzip-JSON 传输封装（Dart 侧用 GZipCodec 解，钉死 packBundle/unpackBundle 互通）。 */
  packedBundleBase64: packBundle(envelope, signature).toString("base64"),

  cases: [
    {
      name: "valid_official",
      _why: "正例：digest 对、身份对、签名对 → 裁定 official",
      envelope,
      signature,
      publicKeyRawHex: rawPub.toString("hex"),
      expect: { ok: true, tier: "official" },
    },
    {
      name: "tampered_content",
      _why: "内容寻址：改一字节即 digest 不符 → 拒（fail-closed）",
      envelope: tamperedEnvelope,
      signature,
      publicKeyRawHex: rawPub.toString("hex"),
      expect: { ok: false, reasonContains: "digest" },
    },
    {
      name: "wrong_public_key",
      _why: "非预埋 pin 公钥签的 → 拒",
      envelope,
      signature,
      publicKeyRawHex: otherRawPub.toString("hex"),
      expect: { ok: false, reasonContains: "验签" },
    },
    {
      name: "identity_confusion",
      _why:
        "🔒 ADR-002 §2.2：digest 真、Ed25519 真，但签名身份 ≠ envelope 内 manifest。" +
        "运行时用的是 bundle 内 manifest（定 allow/credentials），不核对即身份混淆 → 必须拒",
      envelope,
      signature: forgedIdentity,
      publicKeyRawHex: rawPub.toString("hex"),
      expect: { ok: false, reasonContains: "身份" },
    },
    {
      name: "unsupported_algorithm",
      _why: "算法降级：非 ed25519 一律拒，不做任何回退",
      envelope,
      signature: { ...signature, algorithm: "rsa-sha256" },
      publicKeyRawHex: rawPub.toString("hex"),
      expect: { ok: false, reasonContains: "算法" },
    },
    {
      name: "missing_manifest",
      _why:
        "🔒 envelope 无 manifest.json，但 digest 与 Ed25519 **都真**（对这份 envelope 而言）——" +
        "故会一路走到身份核对。无权威身份来源时必须拒，**不得**退化为采信签名自报的 adapterId" +
        "（ADR-002 §2.2）。签端 signEnvelope 本就拒签这种 envelope，此为验端的纵深防御。",
      envelope: noManifestEnvelope,
      signature: noManifestSig,
      publicKeyRawHex: rawPub.toString("hex"),
      expect: { ok: false, reasonContains: "manifest" },
    },
    {
      name: "valid_signature_sideload_tier",
      _why:
        "🔒 tier=sideload 但**签名对同一 envelope、同一密钥有效**——通过 算法/格式/digest/身份/公钥/Ed25519，" +
        "**只在第 7 步（档位）被拒**。真正验证「验签只裁定 official，远程签名不能自称 sideload 进 dev 档」" +
        "（ADR-002 §2.5）。与 wrong_public_key 的区别：那个在第 5 步就拒、根本测不到档位语义。",
      envelope,
      signature: sideloadSig,
      publicKeyRawHex: rawPub.toString("hex"),
      expect: { ok: false, reasonContains: "档位" },
    },
  ],
};

const out = `${repoRoot}contract/golden/bundle/loader.json`;
writeFileSync(out, `${JSON.stringify(golden, null, 2)}\n`);
console.log(`已写出 ${out}`);
console.log(`  digest : ${digest}`);
console.log(`  pubkey : ${rawPub.toString("hex")}`);
console.log(`  cases  : ${golden.cases.length}`);
