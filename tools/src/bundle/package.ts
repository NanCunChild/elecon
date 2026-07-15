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
import { type SignatureFile, serializePayload } from "../signer/index.js";
import { type BundleEnvelope, envelopeDigest } from "./envelope.js";

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

export interface IntegrityResult {
  ok: boolean;
  reason?: string;
}

/**
 * 内容寻址完整性校验（**keyless**）：重算 envelope digest,与签名声明的 digest 比对。
 * 捕获传输损坏/篡改（解包后不信任传输层元数据,只信内容寻址）。**不含** Ed25519 验签。
 */
export function verifyBundleIntegrity(
  env: BundleEnvelope,
  signature: Pick<SignatureFile, "digest">,
): IntegrityResult {
  const digest = envelopeDigest(env);
  if (digest !== signature.digest) {
    return {
      ok: false,
      reason: `digest 不符：算得 ${digest.slice(0, 12)}… 期望 ${signature.digest.slice(0, 12)}…`,
    };
  }
  return { ok: true };
}

/**
 * 🔒 Ed25519 验签（复用 signer `serializePayload`）。先内容寻址校验 digest,再验签名载荷。
 * 需传入 active pin 公钥——**信任裁定与加载决定不在此**（🔒 加载器,ADR-002 §2.6）。
 * 返回 false 即 fail-closed。
 */
export function verifyBundleSignature(
  env: BundleEnvelope,
  signature: SignatureFile,
  publicKey: KeyObject,
): boolean {
  if (signature.algorithm !== "ed25519") return false;
  if (!verifyBundleIntegrity(env, signature).ok) return false;
  const payload = serializePayload({
    adapterId: signature.adapterId,
    adapterVersion: signature.adapterVersion,
    tier: signature.tier,
    digest: signature.digest,
  });
  return edVerify(null, payload, publicKey, Buffer.from(signature.signature, "base64"));
}
