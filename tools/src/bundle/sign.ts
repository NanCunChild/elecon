/**
 * 🔒 对 bundle envelope 签名（ADR-018 §2.9）—— 产出 detached SignatureFile。
 *
 * envelope digest === signer 目录式 digest（见 envelope.ts 不变量），故签 envelope 得到的签名
 * 与签目录**互通**。tier 由**签名流程显式注入**（§2.2），非 manifest 自报。配对验签见
 * `package.ts` 的 `verifyBundleSignature`。
 *
 * **身份不取自调用方**：adapterId/adapterVersion 一律从 envelope 内 `manifest.json` 读取
 * （`readEnvelopeManifest`）——manifest.json 在 digest 覆盖内，故「签名身份」与「被签内容」
 * 结构性一致，杜绝签出「内容 A / 身份 B」的签名（ADR-002 §2.2）。同 `signAdapter` 从目录
 * manifest 取身份的取向。
 *
 * 🔒 承重路径（红线 #4）。签名后端(YubiKey)接线与闭环须人工（AGENTS.md §1）;本函数只做
 *    "读身份 → 算 digest → 拼 payload → 交后端签"的确定性编排,不含私钥操作。
 */

import type { SignatureFile, SignBackend, TrustTier } from "../signer/index.js";
import { serializePayload } from "../signer/index.js";
import { type BundleEnvelope, envelopeDigest, readEnvelopeManifest } from "./envelope.js";

/**
 * 对 envelope 签名 → SignatureFile（digest = envelopeDigest；身份取自 envelope 内 manifest.json）。
 * envelope 缺/损坏 manifest.json 时抛错（fail-closed，绝不签无法确定身份的内容）。
 */
export async function signEnvelope(
  env: BundleEnvelope,
  tier: TrustTier,
  backend: SignBackend,
): Promise<SignatureFile> {
  const { adapterId, adapterVersion } = readEnvelopeManifest(env); // 权威身份，非调用方传入
  const digest = envelopeDigest(env);
  const payload = serializePayload({ adapterId, adapterVersion, tier, digest });
  const signature = await backend.sign(payload);
  return {
    adapterId,
    adapterVersion,
    tier,
    digest,
    signature,
    keyId: backend.keyId,
    algorithm: "ed25519",
  };
}
