/**
 * 🔒 catalog 签名 / 验签（ADR-018 §2.5）—— 与 adapter bundle **同一 Ed25519 / YubiKey 公钥集**。
 *
 * **字节精确签名（byte-exact）**：签名对象 = catalog 的**原始 JSON 字节**;这份字节被原样携带
 * （`SignedCatalog.catalogJson`）、原样传输、原样验签、验过后才 parse。**签 / 传 / 验 / 解析用的
 * 是同一份字节**。
 *
 * 为何不"重新规范化序列化"：手写字段列表的 `serialize()` 会**静默漂移**——schema/类型新增字段而
 * 序列化没跟上，该字段就落在**签名范围之外**（CDN 可随意改它而签名仍有效）;这种漂移还会**跨语言**
 * （Dart 加载器需再实现一份同样的规范化）。字节精确从根上消除两者：新增字段自动进签名范围，
 * Dart 侧只需"验字节 → 再 parse"，零规范化、零漂移。
 *
 * 验签返回**已解析的 catalog**（统一 `VerifyResult`）——调用方只能经 `ok:true` 拿到它，
 * 无法误用未验签数据。**防回滚(sequence)/TTL/last-good/是否采用**仍由 🔒 加载器裁定，不在此。
 *
 * 🔒 承重路径（红线 #4）。签名后端接线与闭环须人工（AGENTS.md §1）。
 */

import { verify as edVerify, type KeyObject } from "node:crypto";
import { CONTEXT_TAG_CATALOG, type SignBackend, type VerifyResult, withContext } from "../signer/index.js";
import type { Catalog } from "./validate.js";

export interface SignedCatalog {
  /** 被签名的 catalog **原始 JSON 文本**（签/传/验/parse 同一份字节）。 */
  catalogJson: string;
  /** Ed25519 签名（base64）over `Buffer.from(catalogJson, "utf-8")`。 */
  signature: string;
  keyId: string;
  algorithm: "ed25519";
}

/** 🔒 对 catalog 签名 → SignedCatalog（序列化**恰好一次**，此后只用这份字节）。 */
export async function signCatalog(catalog: Catalog, backend: SignBackend): Promise<SignedCatalog> {
  const catalogJson = JSON.stringify(catalog);
  // 域分隔（ADR-002 §2.3）：签的是 `elecon.catalog/1 ‖ 0x00 ‖ catalogJson 字节`。
  // **传输对象不变**——`catalogJson` 仍原样携带，前缀只加在签/验输入上。
  const signature = await backend.sign(withContext(CONTEXT_TAG_CATALOG, Buffer.from(catalogJson, "utf-8")));
  return { catalogJson, signature, keyId: backend.keyId, algorithm: "ed25519" };
}

/**
 * 🔒 验签 catalog（对 pin 公钥;fail-closed）→ 成功返回**已解析** catalog。
 * **信任哪把公钥 + 是否采用（防回滚/TTL）** 由加载器裁定，不在此。
 */
export function verifyCatalog(signed: SignedCatalog, publicKey: KeyObject): VerifyResult<Catalog> {
  if (signed.algorithm !== "ed25519") {
    return { ok: false, reason: `不支持的签名算法：${signed.algorithm}` };
  }
  const bytes = withContext(CONTEXT_TAG_CATALOG, Buffer.from(signed.catalogJson, "utf-8"));
  if (!edVerify(null, bytes, publicKey, Buffer.from(signed.signature, "base64"))) {
    return { ok: false, reason: "Ed25519 验签失败 → fail-closed。" };
  }
  try {
    return { ok: true, value: JSON.parse(signed.catalogJson) as Catalog };
  } catch (err) {
    return { ok: false, reason: `catalog JSON 解析失败：${(err as Error).message}` };
  }
}
