/**
 * revocation golden 漂移闸门 + TS 自验 smoke（同 catalog-golden.smoke）。
 *
 *  - 漂移闸门：重生成须与已提交 `contract/golden/revocation/revocation.json` 逐字节相同。
 *  - TS 自验：TS `verifyRevocation` 验过 valid、拒 tampered/wrong-key/bad-algo，与 Dart 侧同判。
 *
 *   运行：cd tools && npx tsx src/signer/revocation-golden.smoke.ts（或 npm run smoke:all 自动发现）
 */

import { createPublicKey, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { buildRevocationGolden, REVOCATION_GOLDEN_PATH } from "./make-revocation-golden.js";
import { type SignedRevocationList, verifyRevocation } from "./revocation.js";

let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    console.log(`  ok  ${msg}`);
  } else {
    failed++;
    console.error(`  FAIL ${msg}`);
  }
}

const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
function pubFromRawHex(hex: string): KeyObject {
  return createPublicKey({
    key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(hex, "hex")]),
    format: "der",
    type: "spki",
  });
}

async function main(): Promise<void> {
  const rebuilt = `${JSON.stringify(await buildRevocationGolden(), null, 2)}\n`;
  const committed = readFileSync(REVOCATION_GOLDEN_PATH, "utf-8");
  check(rebuilt === committed, "重生成与已提交 golden 逐字节一致（否则重跑 make-revocation-golden.ts）");

  const golden = JSON.parse(committed) as {
    cases: {
      name: string;
      signed: { listJson: string; signature: string; keyId: string; algorithm: string };
      publicKeyRawHex: string;
      expect: { ok: boolean };
    }[];
  };
  for (const c of golden.cases) {
    // algorithm 在 golden 里是 string（降级 case 刻意 "rsa"）；verifyRevocation 运行时检查算法，
    // 故 downcast 到 SignedRevocationList（字面量 "ed25519"）以喂给类型化入口。
    const r = verifyRevocation(c.signed as SignedRevocationList, pubFromRawHex(c.publicKeyRawHex));
    check(r.ok === c.expect.ok, `${c.name}: TS 验签${c.expect.ok ? "通过" : "拒"}`);
  }

  if (failed > 0) {
    console.error(`revocation-golden smoke: ${failed} 项失败`);
    process.exit(1);
  }
  console.log("revocation-golden smoke: 全通过");
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
