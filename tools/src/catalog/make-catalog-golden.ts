/**
 * 生成 `contract/golden/catalog/catalog.json` —— **Node 签端 × Dart 🔒 加载器**的 catalog
 * 跨语言验签 golden 向量。
 *
 * 为何需要：catalog 签名是**字节精确**（Ed25519 over `utf8(catalogJson)`）。残余风险在跨平台
 * 实现一致性——Node `Buffer.from(catalogJson,"utf8")` 与 Dart `utf8.encode(catalogJson)` 必须
 * 逐字节相同，否则验签静默失败（好）或验过不该验的（灾难）。用同一份向量把两端钉死。
 *
 * 两段覆盖：
 *  ① `byteInterop` —— 与 schema **解耦**的纯 UTF-8 字节探针（中文/emoji/组合字符 NFD/CRLF/转义/
 *     星平面）。catalog 的受约束字段无法承载换行/转义，故在此直接比对 `Buffer.from(...,"utf8")`
 *     与 Dart `utf8.encode` 的字节，证两端**都不做归一化**（NFC/换行改写）。
 *  ② `cases` —— 端到端：Node `signCatalog` 真实签名 + Dart `verifyCatalogWith` 验签。含一个
 *     `adapterId` 带**中文+emoji**的合法 catalog（`^school-\S+$` 允许非空白多字节），证完整
 *     "验签→解析"多字节保真；外加篡改/错公钥/降级负例。
 *
 * 确定性：固定测试种子 + Ed25519 确定性（RFC 8032）+ JSON.stringify 插入序 → 重跑**逐字节相同**。
 * `catalog-golden.smoke.ts` 断言"重生成 == 已提交"（漂移即 CI 红）。
 *
 * ⚠ 种子是**纯测试夹具**，与生产签名密钥（离线 YubiKey 片上生成、永不导出）无任何关系，
 *   **绝不可**出现在 client 预埋 pin 集（trust_anchors.dart）。🔒 改动触碰红线 #4 验签路径，须人工审。
 *
 *   运行：cd tools && npx tsx src/catalog/make-catalog-golden.ts
 */

import { createPrivateKey, createPublicKey, sign as edSign } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { SignBackend } from "../signer/index.js";
import { signCatalog, verifyCatalog } from "./sign.js";
import type { Catalog } from "./validate.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
export const CATALOG_GOLDEN_PATH = `${repoRoot}contract/golden/catalog/catalog.json`;

// Ed25519 PKCS#8 前缀（RFC 8410）；固定种子 → 确定性测试密钥（非生产密钥，见文件头警告）。
const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
function keyFromSeed(seed: string): { priv: ReturnType<typeof createPrivateKey>; rawPubHex: string } {
  const s = Buffer.from(seed, "utf-8");
  if (s.length !== 32) throw new Error(`种子须 32 字节，得 ${s.length}：${seed}`);
  const priv = createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519_PREFIX, s]),
    format: "der",
    type: "pkcs8",
  });
  const rawPub = createPublicKey(priv).export({ format: "der", type: "spki" }).subarray(-32);
  return { priv, rawPubHex: rawPub.toString("hex") };
}

const TEST = keyFromSeed("elecon-catalog-golden-test-seed!");
const OTHER = keyFromSeed("elecon-catalog-golden-OTHER-seed");
const KEY_ID = "golden-catalog-key";

function backend(priv: ReturnType<typeof createPrivateKey>): SignBackend {
  return {
    keyId: KEY_ID,
    async sign(payload: Buffer) {
      return edSign(null, payload, priv).toString("base64");
    },
  };
}

// ① UTF-8 字节探针（与 schema 解耦）。刻意含：组合字符（NFD，证不归一）、CRLF/CR/LF、
//    JSON 转义字符（" \ / \t）、BMP 外星平面字符。
const _probes: [string, string][] = [
  ["ascii", "hello world"],
  ["chinese", "西安电子科技大学 通知列表"],
  ["emoji", "🔒🎓✅🚀"],
  ["combining_nfd", "é café"], // e + U+0301 组合尖音（NFD 形态）
  ["escapes", 'quote " backslash \\ slash / tab\t'],
  ["newlines", "lf\n crlf\r\n cr\r end"],
  ["astral", "\u{1D54F} \u{1F600} \u{1D7D9}"], // 𝕏 😀 𝟙
  ["mixed", '校园-🔒-a\\b"c\n西电'],
];

// ② 端到端：合法 catalog，adapterId 带中文+emoji。
const validCatalog: Catalog = {
  catalogVersion: "1.0",
  sequence: 7,
  issuedAt: "2026-07-17T00:00:00Z",
  ttlSeconds: 3600,
  entries: [
    {
      adapterId: "school-西电🔒",
      adapterVersion: "1.2.0",
      digest: "a".repeat(64),
      capabilities: ["notice.list"],
    },
    {
      adapterId: "school-xjt",
      adapterVersion: "0.9.1",
      digest: "b".repeat(64),
      stdlibMin: "1.0.0",
      capabilities: ["notice.list", "grades.list"],
    },
  ],
};

export async function buildCatalogGolden(): Promise<Record<string, unknown>> {
  const signed = await signCatalog(validCatalog, backend(TEST.priv));

  // 生成器自检：TS 侧应能验过自己签的（catch 生成器 bug）。
  const selfCheck = verifyCatalog(signed, createPublicKey(TEST.priv));
  if (!selfCheck.ok) throw new Error(`生成器自检失败：${selfCheck.reason}`);

  const byteInterop = _probes.map(([name, text]) => ({
    name,
    text,
    utf8Base64: Buffer.from(text, "utf-8").toString("base64"),
  }));

  return {
    _doc:
      "Node 签端 × Dart 🔒 加载器的 catalog 跨语言验签 golden（字节精确：Ed25519 over utf8(catalogJson)）。" +
      "byteInterop 证 Buffer.from(...,'utf8') == Dart utf8.encode（两端均不归一化）；cases 证端到端验签+解析。" +
      "**改动触碰红线 #4 验签路径，须人工 + 安全清单复核。**",
    _generator: "tools/src/catalog/make-catalog-golden.ts（确定性；重跑应产出逐字节相同的文件）",
    _keyNote:
      "publicKeyRawHex 是**测试**公钥（固定种子派生，Ed25519 确定性）。与生产签名密钥无关，" +
      "**绝不可**出现在 client 预埋 pin 集（client/lib/core/loader/trust_anchors.dart）。",

    publicKeyRawHex: TEST.rawPubHex,
    otherPublicKeyRawHex: OTHER.rawPubHex,

    byteInterop,

    cases: [
      {
        name: "valid_multibyte_identity",
        _why: "正例：adapterId 含中文+emoji，验签过 + 解析保真（证 Node utf8 签 == Dart utf8 验）",
        signed,
        publicKeyRawHex: TEST.rawPubHex,
        expect: { ok: true, adapterId0: "school-西电🔒" },
      },
      {
        name: "tampered_catalog_json",
        _why: "字节精确：改一处即 utf8 字节变 → Ed25519 验签失败（fail-closed）",
        signed: { ...signed, catalogJson: signed.catalogJson.replace('"sequence":7', '"sequence":8') },
        publicKeyRawHex: TEST.rawPubHex,
        expect: { ok: false, reasonContains: "验签" },
      },
      {
        name: "wrong_public_key",
        _why: "非该测试密钥签的（换成另一把公钥）→ 拒",
        signed,
        publicKeyRawHex: OTHER.rawPubHex,
        expect: { ok: false, reasonContains: "验签" },
      },
      {
        name: "unsupported_algorithm",
        _why: "算法降级：非 ed25519 一律拒，不回退",
        signed: { ...signed, algorithm: "rsa" },
        publicKeyRawHex: TEST.rawPubHex,
        expect: { ok: false, reasonContains: "算法" },
      },
    ],
  };
}

async function writeGolden(): Promise<void> {
  const golden = await buildCatalogGolden();
  mkdirSync(dirname(CATALOG_GOLDEN_PATH), { recursive: true });
  writeFileSync(CATALOG_GOLDEN_PATH, `${JSON.stringify(golden, null, 2)}\n`);
  console.log(`已写出 ${CATALOG_GOLDEN_PATH}`);
  console.log(`  pubkey : ${TEST.rawPubHex}`);
  console.log(`  probes : ${(golden.byteInterop as unknown[]).length}`);
  console.log(`  cases  : ${(golden.cases as unknown[]).length}`);
}

const isMain = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) await writeGolden();
