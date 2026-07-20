/**
 * bootstrap 派生 smoke：验证「dist → client/assets/bootstrap」纯字节派生与 --check 漂移守卫。
 * 用临时 dist 树（非真实签名产物），只测搬字节 / 比对逻辑。
 */

import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { syncBootstrap } from "./bootstrap.js";

const root = mkdtempSync(join(tmpdir(), "elecon-bootstrap-"));
const dist = join(root, "dist");
const assets = join(root, "assets");
const digest = "a".repeat(64);

mkdirSync(join(dist, "bundles"), { recursive: true });
const catalogPlain = Buffer.from(
  JSON.stringify({ catalogJson: "{}", signature: "s", keyId: "k", algorithm: "ed25519" }),
  "utf8",
);
const revocationBytes = Buffer.from(
  `${JSON.stringify({ listJson: "{}", signature: "s", keyId: "k", algorithm: "ed25519" })}\n`,
  "utf8",
);
const bundleBytes = gzipSync(Buffer.from("packed-bundle-bytes", "utf8"));
writeFileSync(join(dist, "catalog.json.gz"), gzipSync(catalogPlain));
writeFileSync(join(dist, "revocation.json"), revocationBytes);
writeFileSync(join(dist, "bundles", `${digest}.json.gz`), bundleBytes);

try {
  // 写盘派生：三个资产字节应与 dist 源一致。
  const result = syncBootstrap({ distDir: dist, assetsDir: assets });
  assert.deepEqual(
    result.written.sort(),
    ["bundles/" + digest + ".bundle", "catalog.json", "revocation.json"].sort(),
  );
  assert.ok(readFileSync(join(assets, "catalog.json")).equals(catalogPlain), "catalog 应为 gunzip 后明文");
  assert.ok(readFileSync(join(assets, "revocation.json")).equals(revocationBytes), "revocation 应逐字节复制");
  assert.ok(
    readFileSync(join(assets, "bundles", `${digest}.bundle`)).equals(bundleBytes),
    "bundle 应逐字节复制、仅换扩展名",
  );

  // check 模式：刚派生完应无漂移。
  assert.deepEqual(syncBootstrap({ distDir: dist, assetsDir: assets, check: true }).drift, []);

  // 篡改一个资产 → check 应检出漂移。
  writeFileSync(join(assets, "revocation.json"), Buffer.from("tampered", "utf8"));
  assert.deepEqual(syncBootstrap({ distDir: dist, assetsDir: assets, check: true }).drift, [
    "revocation.json",
  ]);

  // 非 digest 文件名 → fail-closed 拒绝。
  writeFileSync(join(dist, "bundles", "not-a-digest.json.gz"), bundleBytes);
  assert.throws(() => syncBootstrap({ distDir: dist, assetsDir: assets }), /digest/);

  console.log("bootstrap 派生 smoke 全部通过");
} finally {
  rmSync(root, { recursive: true, force: true });
}
