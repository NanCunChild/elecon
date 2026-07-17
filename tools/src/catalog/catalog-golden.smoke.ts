/**
 * catalog golden 漂移闸门 + TS 自验 smoke。
 *
 *  - **漂移闸门**：重跑生成器的产物须与已提交 `contract/golden/catalog/catalog.json` **逐字节相同**
 *    （生成器确定性）。改了生成器却忘重跑 → 此处红，避免 Dart 消费的是陈旧向量。
 *  - **TS 自验**：TS `verifyCatalog` 应验过 valid、拒 tampered/wrong-key/bad-algo，与 Dart 侧同判
 *    （`client/test/loader_catalog_golden_test.dart`）。
 *
 *   运行：cd tools && npx tsx src/catalog/catalog-golden.smoke.ts（或 npm run smoke:all 自动发现）
 */

import { createPublicKey, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { buildCatalogGolden, CATALOG_GOLDEN_PATH } from "./make-catalog-golden.js";
import { type SignedCatalog, verifyCatalog } from "./sign.js";

let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    console.log(`  ok  ${msg}`);
  } else {
    failed++;
    console.error(`  FAIL ${msg}`);
  }
}

// 用 golden 里的 raw 公钥 hex 造 KeyObject（SPKI DER 前缀 + 32B）。
const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
function pubFromRawHex(hex: string): KeyObject {
  return createPublicKey({
    key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(hex, "hex")]),
    format: "der",
    type: "spki",
  });
}

async function main(): Promise<void> {
  // 1) 漂移闸门。
  const rebuilt = `${JSON.stringify(await buildCatalogGolden(), null, 2)}\n`;
  const committed = readFileSync(CATALOG_GOLDEN_PATH, "utf-8");
  check(rebuilt === committed, "重生成与已提交 golden 逐字节一致（否则重跑 make-catalog-golden.ts）");

  // 2) TS 自验各 case。
  const golden = JSON.parse(committed) as {
    cases: {
      name: string;
      signed: { catalogJson: string; signature: string; keyId: string; algorithm: string };
      publicKeyRawHex: string;
      expect: { ok: boolean; reasonContains?: string };
    }[];
  };
  for (const c of golden.cases) {
    // algorithm 在 golden 里是 string（降级 case 刻意为 "rsa"）；verifyCatalog 本就在运行时
    // 检查算法，故此处 downcast 到 SignedCatalog（字面量 "ed25519"）以喂给类型化入口。
    const r = verifyCatalog(c.signed as SignedCatalog, pubFromRawHex(c.publicKeyRawHex));
    if (c.expect.ok) {
      check(r.ok, `${c.name}: TS 验签通过`);
    } else {
      check(!r.ok, `${c.name}: TS 验签拒`);
    }
  }

  if (failed > 0) {
    console.error(`catalog-golden smoke: ${failed} 项失败`);
    process.exit(1);
  }
  console.log("catalog-golden smoke: 全通过");
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
