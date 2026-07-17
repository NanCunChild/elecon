/**
 * 生成 `contract/golden/revocation/revocation.json` —— **Node 签端 × Dart 🔒 加载器**的吊销清单
 * 跨语言验签 golden 向量。字节精确（Ed25519 over `utf8(listJson)`，同 SignedCatalog）。
 *
 * 与 catalog golden 的差别：RevocationList 的 `reason` 是**自由文本字段**（schema 合法），故
 * 多字节/换行/转义/组合字符可直接进一个**合法**清单，由端到端"验签→解析"证互操作——比 catalog
 * 当时的解耦 byteInterop 探针更强（catalog 无自由文本字段）。因此本 golden 不再单列 byteInterop：
 * 富文本 `reason` + 中文/emoji 的 `adapterId` 已覆盖 `Buffer.from(...,"utf8")` == Dart `utf8.encode`。
 *
 * 确定性：固定测试种子 + Ed25519 确定性 + JSON.stringify 插入序 → 重跑逐字节相同；
 * `revocation-golden.smoke.ts` 断言"重生成 == 已提交"。
 *
 * ⚠ 种子是纯测试夹具，与生产签名密钥无关，**绝不可**进 client 预埋 pin 集。🔒 改动触碰红线 #4。
 *
 *   运行：cd tools && npx tsx src/signer/make-revocation-golden.ts
 */

import { createPrivateKey, createPublicKey, sign as edSign } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { SignBackend } from "./index.js";
import { type RevocationList, signRevocation, verifyRevocation } from "./revocation.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
export const REVOCATION_GOLDEN_PATH = `${repoRoot}contract/golden/revocation/revocation.json`;

const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
function keyFromSeed(seed: string): {
  priv: ReturnType<typeof createPrivateKey>;
  rawPubHex: string;
} {
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

const TEST = keyFromSeed("elecon-revocation-golden-test!!!");
const OTHER = keyFromSeed("elecon-revocation-golden-OTHER!!");
const KEY_ID = "golden-revocation-key";

function backend(priv: ReturnType<typeof createPrivateKey>): SignBackend {
  return {
    keyId: KEY_ID,
    async sign(payload: Buffer) {
      return edSign(null, payload, priv).toString("base64");
    },
  };
}

// 富文本 reason：一处塞满 中文 / emoji / 换行(LF) / 引号 / 反斜杠 / 制表 / NFD 组合字符 / 星平面。
// 端到端验签+解析后 Dart 侧须逐字符还原它 → 证 Node utf8 签 == Dart utf8 验，且两端不归一化。
const richReason =
  '密钥泄露事件 🔒\n受影响版本 1.0.0–1.5.0\n引号" 反斜杠\\ 制表\t NFD é 星平面 \u{1D54F}\u{1F600}';

const validList: RevocationList = {
  sequence: 5,
  issuedAt: "2026-07-17T00:00:00Z",
  ttlSeconds: 3600,
  minVersions: { "school-西电🔒": "2.0.0" },
  killSwitch: false,
  entries: [
    { adapterId: "school-西电🔒", digest: "a".repeat(64), reason: richReason },
    {
      adapterId: "school-xjt",
      versionRange: { minInclusive: "1.0.0", maxInclusive: "1.5.0" },
      reason: "版本区间吊销",
    },
  ],
};

export async function buildRevocationGolden(): Promise<Record<string, unknown>> {
  const signed = await signRevocation(validList, backend(TEST.priv));

  const selfCheck = verifyRevocation(signed, createPublicKey(TEST.priv));
  if (!selfCheck.ok) throw new Error(`生成器自检失败：${selfCheck.reason}`);

  return {
    _doc:
      "Node 签端 × Dart 🔒 加载器的 revocation 跨语言验签 golden（字节精确：Ed25519 over utf8(listJson)）。" +
      "valid case 的 reason 富文本 + adapterId 中文/emoji 证端到端 utf8 互操作（两端不归一化）。" +
      "**改动触碰红线 #4 验签路径，须人工 + 安全清单复核。**",
    _generator: "tools/src/signer/make-revocation-golden.ts（确定性；重跑应产出逐字节相同的文件）",
    _keyNote:
      "publicKeyRawHex 是**测试**公钥（固定种子派生）。与生产签名密钥无关，" +
      "**绝不可**出现在 client 预埋 pin 集（client/lib/core/loader/trust_anchors.dart）。",

    publicKeyRawHex: TEST.rawPubHex,
    otherPublicKeyRawHex: OTHER.rawPubHex,

    cases: [
      {
        name: "valid_multibyte_reason",
        _why: "正例：reason 富文本 + adapterId 中文/emoji，验签过 + 解析逐字符保真",
        signed,
        publicKeyRawHex: TEST.rawPubHex,
        expect: { ok: true, entry0AdapterId: "school-西电🔒", entry0Reason: richReason },
      },
      {
        name: "tampered_list_json",
        _why: "字节精确：改一处即 utf8 字节变 → Ed25519 验签失败",
        signed: { ...signed, listJson: signed.listJson.replace('"sequence":5', '"sequence":6') },
        publicKeyRawHex: TEST.rawPubHex,
        expect: { ok: false, reasonContains: "验签" },
      },
      {
        name: "wrong_public_key",
        _why: "非该测试密钥签的 → 拒",
        signed,
        publicKeyRawHex: OTHER.rawPubHex,
        expect: { ok: false, reasonContains: "验签" },
      },
      {
        name: "unsupported_algorithm",
        _why: "算法降级：非 ed25519 一律拒",
        signed: { ...signed, algorithm: "rsa" },
        publicKeyRawHex: TEST.rawPubHex,
        expect: { ok: false, reasonContains: "算法" },
      },
    ],
  };
}

async function writeGolden(): Promise<void> {
  const golden = await buildRevocationGolden();
  mkdirSync(dirname(REVOCATION_GOLDEN_PATH), { recursive: true });
  writeFileSync(REVOCATION_GOLDEN_PATH, `${JSON.stringify(golden, null, 2)}\n`);
  console.log(`已写出 ${REVOCATION_GOLDEN_PATH}`);
  console.log(`  pubkey : ${TEST.rawPubHex}`);
  console.log(`  cases  : ${(golden.cases as unknown[]).length}`);
}

const isMain = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) await writeGolden();
