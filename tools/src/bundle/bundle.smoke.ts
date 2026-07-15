/**
 * bundle envelope + gzip-JSON 传输封装/验签 冒烟（ADR-018 §2.9）。
 *
 * 用真实 adapter（school-xidian）驱动:
 *   ① envelopeDigest(buildEnvelope(dir)) === computeBundleDigest(dir)（与 signer 零漂移,核心不变量）
 *   ② packBundle → unpackBundle 往返一致 + digest 稳定 + 产物是 gzip（magic 1f 8b）
 *   ③ 内容寻址完整性:篡改 envelope → verifyBundleIntegrity 失败
 *   ④ 🔒 Ed25519 验签:dev keypair 签 → verify 通过;篡改 → 拒（fail-closed）
 *
 *   运行：cd tools && npx tsx src/bundle/bundle.smoke.ts
 */

import { strict as assert } from "node:assert";
import { sign as edSign, generateKeyPairSync } from "node:crypto";
import { fileURLToPath } from "node:url";
import { computeBundleDigest, type SignatureFile, serializePayload } from "../signer/index.js";
import { buildEnvelope, envelopeDigest } from "./envelope.js";
import { packBundle, unpackBundle, verifyBundleIntegrity, verifyBundleSignature } from "./package.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const dir = `${repoRoot}adapters/school-xidian`;

// ① envelope digest 与 signer 目录式 digest 逐字节一致（零漂移不变量）
const env = buildEnvelope(dir);
const dDir = computeBundleDigest(dir);
const dEnv = envelopeDigest(env);
assert.equal(dEnv, dDir, `envelope digest 应等于 signer 目录 digest：${dEnv} vs ${dDir}`);
assert.ok(
  env.files.some((f) => f.path === "manifest.json") && env.files.some((f) => f.path === "index.js"),
  "envelope 应含 manifest.json + index.js",
);
assert.ok(
  !env.files.some((f) => f.path.startsWith("fixtures")),
  "envelope 不应含 fixtures（BUNDLE_EXCLUDE）",
);
console.log("  ✓ envelopeDigest === computeBundleDigest（零漂移）");

// 构造一个 detached 签名（dev ed25519 keypair,仅测试用）
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const payload = serializePayload({
  adapterId: "school-xidian",
  adapterVersion: "0.1.0",
  tier: "official",
  digest: dEnv,
});
const signature: SignatureFile = {
  adapterId: "school-xidian",
  adapterVersion: "0.1.0",
  tier: "official",
  digest: dEnv,
  signature: edSign(null, payload, privateKey).toString("base64"),
  keyId: "dev-test",
  algorithm: "ed25519",
};

// ② gzip-JSON 往返一致 + 产物确为 gzip
const packed = packBundle(env, signature);
assert.equal(packed[0], 0x1f, "packBundle 产物应为 gzip（magic byte 0x1f）");
assert.equal(packed[1], 0x8b, "packBundle 产物应为 gzip（magic byte 0x8b）");
const un = unpackBundle(packed);
assert.deepEqual(un.envelope, env, "unpack 后 envelope 应与原一致");
assert.deepEqual(un.signature, signature, "unpack 后 signature 应与原一致");
assert.equal(envelopeDigest(un.envelope), dEnv, "往返后 digest 应稳定");
console.log("  ✓ packBundle → unpackBundle 往返一致 + digest 稳定（gzip）");

// ③ 内容寻址完整性:篡改 envelope → integrity 失败
{
  const tampered = {
    ...un.envelope,
    files: un.envelope.files.map((f) =>
      f.path === "index.js" ? { ...f, content: `${f.content}// tamper` } : f,
    ),
  };
  assert.equal(verifyBundleIntegrity(tampered, signature).ok, false, "篡改后完整性校验应失败");
  assert.equal(verifyBundleIntegrity(un.envelope, signature).ok, true, "未篡改应通过");
  console.log("  ✓ 篡改 envelope → 内容寻址完整性失败（fail-closed）");
}

// ④ 🔒 Ed25519 验签:正例通过,篡改/错 digest 拒
{
  assert.equal(verifyBundleSignature(un.envelope, signature, publicKey), true, "正确签名应验过");

  const tampered = {
    ...un.envelope,
    files: un.envelope.files.map((f) =>
      f.path === "index.js" ? { ...f, content: `${f.content}// tamper` } : f,
    ),
  };
  assert.equal(verifyBundleSignature(tampered, signature, publicKey), false, "篡改 envelope 应验签失败");

  const { publicKey: otherKey } = generateKeyPairSync("ed25519");
  assert.equal(verifyBundleSignature(un.envelope, signature, otherKey), false, "错公钥应验签失败");
  console.log("  ✓ Ed25519 验签：正例过 / 篡改·错公钥拒（fail-closed）");
}

console.log("\nbundle smoke 全部通过 ✅");
