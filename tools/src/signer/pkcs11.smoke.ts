/**
 * PKCS#11 公钥形态转换冒烟（ADR-002 §2.3）—— **不碰硬件**，纯逻辑。
 *
 * 测的是**信任锚的形态**：App 预埋的是**裸 32B Ed25519 公钥**（非证书），而从 PKCS#11
 * `CKA_EC_POINT` 拿到的也是裸字节 —— 两者之间的 SPKI DER 拼装若错一个字节，会得到一把
 * **看似合法、实则错误**的公钥。故此处用「真签名能否验过」来钉死拼装的正确性，
 * 而非只比对字节（比对字节只能证明自洽，证明不了 DER 语义对）。
 *
 * 🔒 真机 PKCS#11 出签（PIN + 触碰）不在此 —— 见 `pkcs11.ts selftest` 与
 *    docs/reference/signing_ceremony.md，须人工闭环（AGENTS.md §1）。
 *
 *   运行：cd tools && npx tsx src/signer/pkcs11.smoke.ts
 */

import { strict as assert } from "node:assert";
import { sign as edSign, verify as edVerify, generateKeyPairSync } from "node:crypto";
import { keyObjectToRawEd25519, rawEd25519ToKeyObject } from "./pkcs11.js";

const { publicKey, privateKey } = generateKeyPairSync("ed25519");

// ① 裸 32B 提取：这就是预埋 pin 的形态
{
  const raw = keyObjectToRawEd25519(publicKey);
  assert.equal(raw.length, 32, "Ed25519 公钥预埋形态应为裸 32 字节");
  console.log("  ✓ keyObjectToRawEd25519 → 裸 32B（预埋 pin 形态）");
}

// ② 往返一致：raw → KeyObject → raw
{
  const raw = keyObjectToRawEd25519(publicKey);
  const rebuilt = rawEd25519ToKeyObject(raw);
  assert.deepEqual(
    rebuilt.export({ format: "der", type: "spki" }),
    publicKey.export({ format: "der", type: "spki" }),
    "raw → KeyObject → SPKI 应与原公钥逐字节一致",
  );
  assert.deepEqual(keyObjectToRawEd25519(rebuilt), raw, "往返后裸字节应稳定");
  console.log("  ✓ raw ↔ KeyObject 往返逐字节一致");
}

// ③ 🔒 关键：手拼的 SPKI 前缀语义正确 —— 重建的公钥能验真签名
//    （字节比对只证自洽；这条才证明 RFC 8410 id-Ed25519 头拼对了）
{
  const raw = keyObjectToRawEd25519(publicKey);
  const rebuilt = rawEd25519ToKeyObject(raw);
  const data = Buffer.from("elecon trust anchor round-trip", "utf-8");
  const sig = edSign(null, data, privateKey);
  assert.ok(edVerify(null, data, rebuilt, sig), "由裸 32B 重建的公钥必须能验过真签名");
  console.log("  ✓ 裸 32B 重建的公钥可验真签名（SPKI 前缀语义正确）");
}

// ④ 负例：另一把密钥的裸公钥不得验过
{
  const { publicKey: other } = generateKeyPairSync("ed25519");
  const rebuiltOther = rawEd25519ToKeyObject(keyObjectToRawEd25519(other));
  const data = Buffer.from("elecon trust anchor round-trip", "utf-8");
  const sig = edSign(null, data, privateKey);
  assert.equal(edVerify(null, data, rebuiltOther, sig), false, "错公钥不得验过（fail-closed）");
  console.log("  ✓ 错公钥重建后仍验不过（fail-closed）");
}

// ⑤ 长度守卫：非 32B 立即拒（防把 SPKI DER 或 CKA_EC_POINT 原样喂进来）
{
  for (const len of [0, 31, 33, 44]) {
    assert.throws(() => rawEd25519ToKeyObject(Buffer.alloc(len)), /32 字节/, `${len}B 应被拒`);
  }
  console.log("  ✓ 非 32B 公钥被拒：0 / 31 / 33 / 44（fail-closed）");
}

console.log("\npkcs11 公钥形态 smoke 全部通过 ✅  —— 真机出签见 signing_ceremony.md（人工闭环）。");
