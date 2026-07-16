/**
 * bundle 传输封装/拆包/验签（ADR-018 §2.9）。
 *
 * on-wire = **`gzip( JSON.stringify({ envelope, signature }) )`**（`.json.gz`）。
 * gzip 在**签名之外**、仅作传输压缩;两端用内建 codec（node:zlib ↔ Dart GZipCodec），🔒 加载器
 * 无自研归档解析。发端:签完 envelope → packBundle。收端:unpackBundle → 内容寻址校验 → 验签。
 *
 * 🔒 `verifyBundleSignature` 触签名验证承重路径（红线 #4）——复用 signer 的 `serializePayload`
 *    + Ed25519 verify（keyless,公钥侧）。**但"信任哪把公钥"与"是否加载"由 🔒 客户端加载器裁定**
 *    （ADR-002 §2.3/§2.6,ADR-018 §2.6），不在此。按 AGENTS.md §1,验签实现须人工审,不得 AI 独自闭环。
 */

import { verify as edVerify, type KeyObject } from "node:crypto";
import { gunzipSync, gzipSync } from "node:zlib";
import { type SignatureFile, serializePayload, type TrustTier, type VerifyResult } from "../signer/index.js";
import {
  type BundleEnvelope,
  type EnvelopeIdentity,
  envelopeDigest,
  readEnvelopeManifest,
} from "./envelope.js";

/** 传输载荷:被 gzip 的 JSON。envelope 是签名对象;signature 为可选 detached 签名。 */
export interface BundlePayload {
  envelope: BundleEnvelope;
  signature?: SignatureFile;
}

/** envelope（+ 可选 detached 签名）→ gzip-JSON 传输字节。 */
export function packBundle(env: BundleEnvelope, signature?: SignatureFile): Buffer {
  const payload: BundlePayload = { envelope: env, signature };
  return gzipSync(Buffer.from(JSON.stringify(payload), "utf-8"));
}

export interface UnpackedBundle {
  envelope: BundleEnvelope;
  signature?: SignatureFile;
}

/** gzip-JSON 传输字节 → { envelope, signature? }。 */
export function unpackBundle(gz: Buffer): UnpackedBundle {
  const json = gunzipSync(gz).toString("utf-8");
  const payload = JSON.parse(json) as BundlePayload;
  if (payload.envelope === undefined) throw new Error("bundle 缺 envelope");
  return { envelope: payload.envelope, signature: payload.signature };
}

/**
 * 内容寻址完整性校验（**keyless**）：重算 envelope digest,与签名声明的 digest 比对。
 * 捕获传输损坏/篡改（解包后不信任传输层元数据,只信内容寻址）。**不含** Ed25519 验签。
 * 成功返回已验证的 digest（统一 `VerifyResult` 约定，见 signer/index.ts）。
 */
export function verifyBundleIntegrity(
  env: BundleEnvelope,
  signature: Pick<SignatureFile, "digest">,
): VerifyResult<string> {
  const digest = envelopeDigest(env);
  if (digest !== signature.digest) {
    return {
      ok: false,
      reason: `digest 不符：算得 ${digest.slice(0, 12)}… 期望 ${signature.digest.slice(0, 12)}…`,
    };
  }
  return { ok: true, value: digest };
}

/**
 * 🔒 Ed25519 验签（复用 signer `serializePayload`）。顺序：算法 → 内容寻址 digest → **身份核对**
 * → Ed25519 验签。全过才返回裁定档位（统一 `VerifyResult`）。
 * 需传入 active pin 公钥——**信任裁定与加载决定不在此**（🔒 加载器,ADR-002 §2.6）。
 *
 * **身份核对（ADR-002 §2.2）**：digest 只绑定内容;签名载荷里的 adapterId/adapterVersion 是另一维。
 * 不核对则「内容 A / 身份 B」的签名可验过,而运行时用的是 bundle 内 manifest（决定 allow/credentials）
 * → 身份混淆。此处与 `signEnvelope`（身份取自 envelope manifest）构成纵深防御：签端不产生、验端不接受。
 */
export function verifyBundleSignature(
  env: BundleEnvelope,
  signature: SignatureFile,
  publicKey: KeyObject,
): VerifyResult<TrustTier> {
  if (signature.algorithm !== "ed25519") {
    return { ok: false, reason: `不支持的签名算法：${signature.algorithm}` };
  }
  const integrity = verifyBundleIntegrity(env, signature);
  if (!integrity.ok) return integrity;

  let identity: EnvelopeIdentity;
  try {
    identity = readEnvelopeManifest(env);
  } catch (err) {
    return { ok: false, reason: (err as Error).message };
  }
  if (signature.adapterId !== identity.adapterId || signature.adapterVersion !== identity.adapterVersion) {
    return {
      ok: false,
      reason: `签名身份与 envelope 内 manifest 不符（签名 ${signature.adapterId}@${signature.adapterVersion} vs manifest ${identity.adapterId}@${identity.adapterVersion}）→ fail-closed（ADR-002 §2.2）。`,
    };
  }

  const payload = serializePayload({
    adapterId: signature.adapterId,
    adapterVersion: signature.adapterVersion,
    tier: signature.tier,
    digest: signature.digest,
  });
  if (!edVerify(null, payload, publicKey, Buffer.from(signature.signature, "base64"))) {
    return { ok: false, reason: "Ed25519 验签失败 → fail-closed。" };
  }
  return { ok: true, value: signature.tier };
}
