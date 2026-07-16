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

// ④ 🔒 Ed25519 验签:正例通过（返回裁定档位）,篡改/错公钥拒
{
  const good = verifyBundleSignature(un.envelope, signature, publicKey);
  assert.equal(good.ok, true, "正确签名应验过");
  assert.equal(good.ok && good.value, "official", "应返回裁定档位 official");

  const tampered = {
    ...un.envelope,
    files: un.envelope.files.map((f) =>
      f.path === "index.js" ? { ...f, content: `${f.content}// tamper` } : f,
    ),
  };
  assert.equal(verifyBundleSignature(tampered, signature, publicKey).ok, false, "篡改 envelope 应验签失败");

  const { publicKey: otherKey } = generateKeyPairSync("ed25519");
  assert.equal(verifyBundleSignature(un.envelope, signature, otherKey).ok, false, "错公钥应验签失败");
  console.log("  ✓ Ed25519 验签：正例过（得档位）/ 篡改·错公钥拒（fail-closed）");
}

// ⑤ signEnvelope（身份取自 envelope manifest）→ verifyBundleSignature 往返（dev backend）
{
  const { LocalDevSignBackend } = await import("../signer/index.js");
  const { signEnvelope } = await import("./sign.js");
  const backend = new LocalDevSignBackend(privateKey, "dev-local");
  const sig = await signEnvelope(un.envelope, "official", backend);
  assert.equal(sig.digest, dEnv, "signEnvelope 的 digest 应 = envelopeDigest");
  assert.equal(sig.adapterId, "school-xidian", "身份应取自 envelope 内 manifest.json，非调用方");
  assert.equal(sig.keyId, "dev-local", "keyId 应来自 backend");
  assert.equal(verifyBundleSignature(un.envelope, sig, publicKey).ok, true, "signEnvelope 产物应验过");
  console.log("  ✓ signEnvelope（身份取自 manifest）→ verifyBundleSignature 往返");
}

// ⑥ 🔒 身份混淆:签名身份 ≠ envelope 内 manifest → 即使 digest 与签名都有效也须拒（ADR-002 §2.2）
{
  const { LocalDevSignBackend } = await import("../signer/index.js");
  const backend = new LocalDevSignBackend(privateKey, "dev-local");

  // 用真实私钥签一份「身份写成 school-evil、digest 却是 xidian 内容」的签名（模拟管线传错身份/恶意签发）
  const forged = await (async () => {
    const { serializePayload } = await import("../signer/index.js");
    const payload = serializePayload({
      adapterId: "school-evil",
      adapterVersion: "9.9.9",
      tier: "official",
      digest: dEnv,
    });
    return {
      adapterId: "school-evil",
      adapterVersion: "9.9.9",
      tier: "official" as const,
      digest: dEnv,
      signature: await backend.sign(payload),
      keyId: "dev-local",
      algorithm: "ed25519" as const,
    };
  })();

  // digest 对得上、Ed25519 也有效——唯一拦得住它的就是身份核对
  assert.equal(verifyBundleIntegrity(un.envelope, forged).ok, true, "digest 本身是对的（前提成立）");
  const r = verifyBundleSignature(un.envelope, forged, publicKey);
  assert.equal(r.ok, false, "身份与 manifest 不符必须拒（否则身份混淆）");
  assert.match(!r.ok ? r.reason : "", /身份与 envelope 内 manifest 不符/, "失败原因应指明身份不符");
  console.log("  ✓ 身份混淆（内容 A / 身份 B）被拒（fail-closed，ADR-002 §2.2）");
}

console.log("\nbundle smoke 全部通过 ✅");
