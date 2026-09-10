/**
 * bundle 传输封套 / 拆包 / 验签（ADR-018 §2.9.1，digest v2）。
 *
 * on-wire = **`gzip( JSON({ envelopeB64, signature, blobs }) )`**（`.json.gz`）。
 * 这个三字段对象叫**传输封套（wire wrapper）**，**不是信封**——bundle 信封是 `envelopeB64`
 * 解码后的那串字节（ADR-000 §2.3.1 术语）。封套不在签名范围内，gzip 亦然（仅传输压缩，
 * 两端用内建 codec：node:zlib ↔ Dart GZipCodec，🔒 加载器无自研归档解析）。
 *
 * **验证顺序不可重排**（ADR-018 §2.9.1，每步都是前一步的前提）：
 *
 *   1. 压缩体上限 → 有界 gunzip           （压缩炸弹护栏）
 *   2. 解析**传输封套**（仅三字段，严格）   ← 验签前唯一允许的解析
 *   3. base64 解码得 envelopeBytes（受上限约束）
 *   4. 算法只认 ed25519                    （不按签名文件自述选算法）
 *   5. SHA-256(envelopeBytes) 比对 signature.digest   （内容寻址）
 *   6. Ed25519 验签（带 contextTag 前缀）   ← **到此为止未 parse 过 envelope**
 *   7. **才** JSON.parse(envelopeBytes)；bundleFormat 严格相等
 *   8. 路径卫生闸门
 *   9. blob 集合精确相等                    ← 多一个 = 夹带通道
 *  10. 逐文件 size 界定 → 长度精确相等 → SHA-256 命中
 *  11. 身份三方一致（签名载荷 ↔ envelope 顶层 ↔ manifest.json）
 *  12. （宿主侧）stdlibMin 门 → 吊销 → 交 QuickJS
 *
 * 第 4/5 步在验签之前是**便宜且收紧**的：它把「验的字节」钉死为「要用的字节」。
 * 第 8 步不能省——签名只证明发布者确实想要这些路径，**不证明路径安全**。
 * 第 9 步是 v2 唯一新增的、可以搞砸的不变量：少一个会被第 10 步抓到，**多一个不会**。
 *
 * 🔒 承重路径（红线 #4）。按 AGENTS.md §1，本文件与其测试不得由 AI 独自闭环。
 * **"信任哪把公钥"与"是否加载"仍由 🔒 客户端加载器裁定**（ADR-002 §2.3/§2.6），不在此。
 */

import { verify as edVerify, type KeyObject } from "node:crypto";
import { gunzipSync, gzipSync } from "node:zlib";
import { type SignatureFile, serializePayload, type TrustTier, type VerifyResult } from "../signer/index.js";
import {
  assertBlobSetExact,
  assertBlobsMatchDescriptors,
  assertIdentityTriple,
  assertPathHygiene,
  type BlobTable,
  type BundleEnvelope,
  envelopeDigest,
  parseEnvelope,
} from "./envelope.js";

/** 压缩体上限（压缩炸弹护栏）。与 Dart `kMaxBundleGzBytes` 对齐。 */
export const MAX_BUNDLE_GZ_BYTES = 512 * 1024;
/** 解压后上限。与 Dart `kMaxBundlePayloadBytes` 对齐。 */
export const MAX_BUNDLE_PAYLOAD_BYTES = 1024 * 1024;

/** 传输封套：三字段，**严格封闭**（验签前唯一被解析的东西，解析面必须最小）。 */
export interface WireWrapper {
  /** base64(envelopeBytes)。**不透明字节串**，不是嵌套对象。 */
  envelopeB64: string;
  signature: SignatureFile;
  /** 按内容哈希寻址（**不按路径**）：sha256 hex → base64(raw bytes)。 */
  blobs: Record<string, string>;
}

/** envelope 字节 + 签名 + blob 表 → gzip-JSON 传输字节。 */
export function packBundle(envelopeBytes: Buffer, signature: SignatureFile, blobs: BlobTable): Buffer {
  const wire: WireWrapper = {
    envelopeB64: envelopeBytes.toString("base64"),
    signature,
    blobs: Object.fromEntries(Object.entries(blobs).map(([h, b]) => [h, b.toString("base64")])),
  };
  return gzipSync(Buffer.from(JSON.stringify(wire), "utf-8"));
}

/** 完整校验通过的 bundle——**只有走完 12 步的调用方能拿到它**。 */
export interface OpenedBundle {
  readonly envelope: BundleEnvelope;
  readonly envelopeBytes: Buffer;
  readonly blobs: BlobTable;
  readonly signature: SignatureFile;
  readonly tier: TrustTier;
}

/** 步骤 1–3：有界 gunzip → 解析传输封套 → 解码 envelopeBytes。**不做任何信任裁定。** */
/**
 * 🔒 严格（规范）base64 解码（§2.9.1 第 3 步「非规范 base64 拒」）。
 *
 * `Buffer.from(s, "base64")` 是**宽松**的：忽略空白、忽略字母表外字符、接受 URL-safe 字母表、
 * 接受填充位不为零的尾字节——只要解码字节命中 digest 就会被放行。内容寻址让这类差异没有信任面
 * 影响（归档 §2.4），但 Dart `base64.decode` 是严格的，两端对同一份封套必须**同判**（ADR-002 §3
 * 风险 5）。规范形 = 标准字母表、正确填充、且 re-encode 逐字等于原串。
 */
function decodeCanonicalBase64(label: string, s: string): Buffer {
  if (s.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) {
    throw new Error(`${label} 非规范 base64（fail-closed）`);
  }
  const bytes = Buffer.from(s, "base64");
  if (bytes.toString("base64") !== s) {
    throw new Error(`${label} 非规范 base64（fail-closed）`);
  }
  return bytes;
}

function readWire(gz: Buffer): { wire: WireWrapper; envelopeBytes: Buffer; blobs: BlobTable } {
  if (gz.length > MAX_BUNDLE_GZ_BYTES) {
    throw new Error(`压缩体 ${gz.length} 字节超上限 ${MAX_BUNDLE_GZ_BYTES}（fail-closed）`);
  }
  const raw = gunzipSync(gz, { maxOutputLength: MAX_BUNDLE_PAYLOAD_BYTES });
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.toString("utf-8"));
  } catch (err) {
    throw new Error(`传输封套不是合法 JSON：${(err as Error).message}（fail-closed）`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("传输封套不是对象（fail-closed）");
  }
  const o = parsed as Record<string, unknown>;
  // 严格封闭：多余字段拒。验签前的解析面必须最小（E8）。
  for (const k of Object.keys(o)) {
    if (k !== "envelopeB64" && k !== "signature" && k !== "blobs") {
      throw new Error(`传输封套含多余字段 ${JSON.stringify(k)}（fail-closed）`);
    }
  }
  if (typeof o.envelopeB64 !== "string") throw new Error("传输封套缺 envelopeB64（fail-closed）");
  if (typeof o.signature !== "object" || o.signature === null) {
    throw new Error("传输封套缺 signature（fail-closed）");
  }
  if (typeof o.blobs !== "object" || o.blobs === null || Array.isArray(o.blobs)) {
    throw new Error("传输封套缺 blobs（fail-closed）");
  }
  const envelopeBytes = decodeCanonicalBase64("envelopeB64", o.envelopeB64);
  if (envelopeBytes.length === 0) throw new Error("envelopeBytes 为空（fail-closed）");
  if (envelopeBytes.length > MAX_BUNDLE_PAYLOAD_BYTES) {
    throw new Error(`envelopeBytes 超上限（fail-closed）`);
  }
  const blobs: BlobTable = {};
  for (const [h, v] of Object.entries(o.blobs as Record<string, unknown>)) {
    if (typeof v !== "string") throw new Error(`blob ${h} 非 base64 字符串（fail-closed）`);
    blobs[h] = decodeCanonicalBase64(`blob ${h}`, v);
  }
  return { wire: o as unknown as WireWrapper, envelopeBytes, blobs };
}

/**
 * 🔒 打开一份 bundle：走完 §2.9.1 的 1–11 步，全过才返回 [OpenedBundle] 与裁定档位。
 *
 * 需传入 active pin 公钥——**信任裁定与加载决定不在此**（🔒 加载器，ADR-002 §2.6）。
 */
export function openBundle(gz: Buffer, publicKey: KeyObject): VerifyResult<OpenedBundle> {
  let wire: WireWrapper;
  let envelopeBytes: Buffer;
  let blobs: BlobTable;
  try {
    ({ wire, envelopeBytes, blobs } = readWire(gz)); // 1–3
  } catch (err) {
    return { ok: false, reason: (err as Error).message };
  }

  const signature = wire.signature;
  if (signature.algorithm !== "ed25519") {
    return { ok: false, reason: `不支持的签名算法：${signature.algorithm}（fail-closed）` }; // 4
  }

  const digest = envelopeDigest(envelopeBytes); // 5
  if (digest !== signature.digest) {
    return {
      ok: false,
      reason: `digest 不符：算得 ${digest.slice(0, 12)}… 期望 ${String(signature.digest).slice(0, 12)}…`,
    };
  }

  // 6 —— 到此为止**未 parse 过 envelope**。签名输入带 contextTag 域分隔（serializePayload）。
  const payload = serializePayload({
    adapterId: signature.adapterId,
    adapterVersion: signature.adapterVersion,
    tier: signature.tier,
    digest: signature.digest,
  });
  let sigBytes: Buffer;
  try {
    sigBytes = decodeCanonicalBase64("signature", signature.signature);
  } catch {
    return { ok: false, reason: "签名字段非 base64（fail-closed）" };
  }
  if (!edVerify(null, payload, publicKey, sigBytes)) {
    return { ok: false, reason: "Ed25519 验签失败 → fail-closed。" };
  }

  try {
    const parsed = parseEnvelope(envelopeBytes); // 7（含 bundleFormat 严格相等）
    assertPathHygiene(parsed.envelope); // 8
    assertBlobSetExact(parsed.envelope, blobs); // 9
    assertBlobsMatchDescriptors(parsed.envelope, blobs); // 10
    assertIdentityTriple(parsed.envelope, blobs, {
      adapterId: signature.adapterId,
      adapterVersion: signature.adapterVersion,
    }); // 11
    return {
      ok: true,
      value: {
        envelope: parsed.envelope,
        envelopeBytes: parsed.bytes,
        blobs,
        signature,
        tier: signature.tier,
      },
    };
  } catch (err) {
    return { ok: false, reason: (err as Error).message };
  }
}

/**
 * **keyless 自验**：走完 1–5、7–11 步，**只跳过第 6 步 Ed25519 验签**（签发侧拿不到公钥）。
 *
 * 用途是签发侧的"别签出一份自己都装不上的东西"——卫生闸门、blob 集合精确相等、身份三方一致
 * 都能在出厂前抓到。**这不是信任裁定**：没有验签就没有 official 背书，故本函数刻意不返回
 * 裁定档位，只返回 digest。收端一律走 [openBundle]。
 */
export function inspectBundle(gz: Buffer): VerifyResult<string> {
  try {
    const { wire, envelopeBytes, blobs } = readWire(gz); // 1–3
    const signature = wire.signature;
    if (signature.algorithm !== "ed25519") {
      return { ok: false, reason: `不支持的签名算法：${signature.algorithm}（fail-closed）` }; // 4
    }
    const digest = envelopeDigest(envelopeBytes); // 5
    if (digest !== signature.digest) {
      return { ok: false, reason: `digest 不符：算得 ${digest.slice(0, 12)}…` };
    }
    const parsed = parseEnvelope(envelopeBytes); // 7
    assertPathHygiene(parsed.envelope); // 8
    assertBlobSetExact(parsed.envelope, blobs); // 9
    assertBlobsMatchDescriptors(parsed.envelope, blobs); // 10
    assertIdentityTriple(parsed.envelope, blobs, {
      adapterId: signature.adapterId,
      adapterVersion: signature.adapterVersion,
    }); // 11
    return { ok: true, value: digest };
  } catch (err) {
    return { ok: false, reason: (err as Error).message };
  }
}

/**
 * 内容寻址完整性校验（**keyless**）：重算 envelope digest，与签名声明的 digest 比对。
 * 捕获传输损坏/篡改。**不含** Ed25519 验签——完整链路请用 [openBundle]。
 */
export function verifyBundleIntegrity(
  envelopeBytes: Buffer,
  signature: Pick<SignatureFile, "digest">,
): VerifyResult<string> {
  const digest = envelopeDigest(envelopeBytes);
  if (digest !== signature.digest) {
    return {
      ok: false,
      reason: `digest 不符：算得 ${digest.slice(0, 12)}… 期望 ${signature.digest.slice(0, 12)}…`,
    };
  }
  return { ok: true, value: digest };
}
