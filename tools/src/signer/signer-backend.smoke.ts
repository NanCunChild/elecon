/**
 * YubiKeySignBackend 管线冒烟（ADR-002 §2.3）—— **仅测本类编排**（委托硬件出签 + 裸 64B 守卫），
 * 用 fake HardwareEd25519Signer（node ed25519 出裸 64B）模拟 YubiKey CKM_EDDSA。
 *
 * 🔒 真实 PKCS#11 接线见 `./pkcs11.ts`（`YubiKeyPkcs11Signer`，2026-07-16 已接线并真机核验）；
 *    真机出签自检（PIN + 触碰）走 `pkcs11.ts selftest`，须人工执行。本文件不碰硬件、不加载生产密钥。
 *
 *   运行：cd tools && npx tsx src/signer/signer-backend.smoke.ts
 */

import { strict as assert } from "node:assert";
import { sign as edSign, verify as edVerify, generateKeyPairSync } from "node:crypto";
import { type HardwareEd25519Signer, UnwiredHardwareSigner, YubiKeySignBackend } from "./index.js";

const { publicKey, privateKey } = generateKeyPairSync("ed25519");

const fakeHw: HardwareEd25519Signer = {
  keyId: "fake-yubikey",
  async signEd25519(data) {
    return edSign(null, data, privateKey); // node ed25519 → 裸 64B，模拟硬件
  },
};

// ① 正常出签 → 裸 64B base64 + 对 pubkey 验签通过 + keyId 透传
{
  const backend = new YubiKeySignBackend(fakeHw);
  assert.equal(backend.keyId, "fake-yubikey", "keyId 应透传自硬件");
  const payload = Buffer.from("payload-bytes");
  const raw = Buffer.from(await backend.sign(payload), "base64");
  assert.equal(raw.length, 64, "Ed25519 应为裸 64 字节");
  assert.ok(edVerify(null, payload, publicKey, raw), "签名应对 pubkey 验证通过");
  console.log("✓ YubiKeySignBackend 出裸 64B + 验签通过 + keyId 透传");
}

// ② 非 64 字节 → fail-closed。过短与**过长**都要拒：过长正是真实误用场景
//    （OpenPGP packet 封装 / DER 包裹会比裸 64B 长）。
{
  const hwOf = (len: number): HardwareEd25519Signer => ({
    keyId: "bad",
    async signEd25519() {
      return Buffer.alloc(len);
    },
  });
  await assert.rejects(
    () => new YubiKeySignBackend(hwOf(63)).sign(Buffer.from("x")),
    /裸 64 字节/,
    "过短（63B）应拒",
  );
  await assert.rejects(
    () => new YubiKeySignBackend(hwOf(65)).sign(Buffer.from("x")),
    /裸 64 字节/,
    "过长（65B）应拒",
  );
  await assert.rejects(
    () => new YubiKeySignBackend(hwOf(70)).sign(Buffer.from("x")),
    /裸 64 字节/,
    "OpenPGP packet 式封装（~70B）应拒",
  );
  console.log("✓ 非裸 64B 签名被拒：过短 63B / 过长 65B / packet 封装 70B（fail-closed）");
}

// ③ 未接线硬件 → 调用即抛
{
  await assert.rejects(
    () => new YubiKeySignBackend(new UnwiredHardwareSigner()).sign(Buffer.from("x")),
    /未接线/,
    "未接线应抛",
  );
  console.log("✓ UnwiredHardwareSigner 未接线即 fail-closed");
}

console.log("\nsigner backend smoke 全部通过 ✅  —— 真机出签见 pkcs11.ts selftest（PIN + 触碰，人工执行）。");
