/**
 * bootstrap 派生 smoke：验证「dist → client/assets/bootstrap」纯字节派生与 --check 漂移守卫。
 * 用临时 dist 树（非真实签名产物），只测搬字节 / 比对逻辑。
 */

import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gunzipSync, gzipSync } from "node:zlib";
import type { SignBackend } from "../signer/index.js";
import { exportDist, syncBootstrap, verifyBootstrapAssets } from "./bootstrap.js";
import { buildRelease } from "./package.js";

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

  // ---- verify / export：用 fake backend 出一棵真实结构的 dist（envelope digest 可重算）。
  const adapters = join(root, "adapters");
  const adapter = join(adapters, "school-test");
  mkdirSync(adapter, { recursive: true });
  writeFileSync(
    join(adapter, "manifest.json"),
    JSON.stringify({
      manifestVersion: "1.0",
      adapterId: "school-test",
      adapterVersion: "1.0.0",
      schoolId: "test",
      displayName: "Test School",
      trustTier: "official",
      runtime: { engine: "quickjs", entry: "index.js", stdlibMin: "1.0.0" },
      network: { allow: ["https://example.edu/*"] },
      capabilities: [
        {
          id: "notice.list",
          requestGraph: "declarative",
          emits: { schema: "elecon.notice.list", schemaVersion: "1.1" },
          params: { schema: "elecon.params.notice.list", schemaVersion: "1.0" },
          requests: [{ key: "raw", method: "GET", url: "https://example.edu/notice" }],
        },
      ],
    }),
  );
  writeFileSync(join(adapter, "index.js"), "export const capabilities = {};\n");
  // official bundle 自 `elecon-bundle/3` 起必须携带 masker.json（ADR-026 §2.7.1）。
  writeFileSync(join(adapter, "masker.json"), '{"schemaVersion":1,"rules":[]}\n');
  const fake: SignBackend = {
    keyId: "test-release-key",
    async sign() {
      return Buffer.alloc(64, 7).toString("base64");
    },
  };
  const realDist = join(root, "real-dist");
  const realAssets = join(root, "real-assets");
  const release = await buildRelease(
    {
      adaptersRoot: adapters,
      outputDir: realDist,
      sequence: 9,
      issuedAt: "2026-09-11T00:00:00Z",
      ttlSeconds: 86400,
      revocation: {
        sequence: 2,
        issuedAt: "2026-09-11T00:00:00Z",
        ttlSeconds: 86400,
        minVersions: {},
        killSwitch: false,
        entries: [],
      },
    },
    fake,
  );
  syncBootstrap({ distDir: realDist, assetsDir: realAssets });

  // verify：刚 sync 完应自洽。
  assert.deepEqual(verifyBootstrapAssets(realAssets), [], "sync 后的 bootstrap 应自洽");

  // export：反向导出的 dist 与仪式产物在**签名范围内**逐字节相同（bundle 原样、revocation 原样、
  // catalog 的内层 catalogJson 原样；catalog.json.gz 的 gzip 外壳允许不同）。
  const exported = join(root, "exported");
  const written = exportDist({ assetsDir: realAssets, distDir: exported });
  const bundleDigest = release.bundleDigests[0];
  assert.ok(bundleDigest !== undefined);
  assert.deepEqual(
    written.sort(),
    ["bundles/" + bundleDigest + ".json.gz", "catalog.json.gz", "revocation.json"].sort(),
  );
  assert.ok(
    readFileSync(join(exported, "bundles", `${bundleDigest}.json.gz`)).equals(
      readFileSync(join(realDist, "bundles", `${bundleDigest}.json.gz`)),
    ),
    "导出的 bundle 应与仪式产物逐字节相同",
  );
  assert.ok(
    readFileSync(join(exported, "revocation.json")).equals(readFileSync(join(realDist, "revocation.json"))),
    "导出的 revocation 应逐字节相同",
  );
  const exportedCatalog = JSON.parse(
    gunzipSync(readFileSync(join(exported, "catalog.json.gz"))).toString("utf8"),
  ) as {
    catalogJson: string;
  };
  const originalCatalog = JSON.parse(
    gunzipSync(readFileSync(join(realDist, "catalog.json.gz"))).toString("utf8"),
  ) as {
    catalogJson: string;
  };
  assert.equal(exportedCatalog.catalogJson, originalCatalog.catalogJson, "被签的 catalogJson 应逐字节相同");
  // 导出树再 sync 回来应零漂移（往返闭合）。
  assert.deepEqual(syncBootstrap({ distDir: exported, assetsDir: realAssets, check: true }).drift, []);

  // verify 负例：游离 bundle（catalog 未引用）→ 报；缺失 bundle → 报；文件名与 digest 不符 → 报。
  const stray = join(realAssets, "bundles", `${"c".repeat(64)}.bundle`);
  writeFileSync(stray, readFileSync(join(realAssets, "bundles", `${bundleDigest}.bundle`)));
  const strayProblems = verifyBootstrapAssets(realAssets);
  assert.ok(
    strayProblems.some((p) => p.includes("游离")),
    "游离 bundle 应被报出",
  );
  assert.ok(
    strayProblems.some((p) => p.includes("不符")),
    "文件名与 envelope digest 不符应被报出",
  );
  assert.throws(() => exportDist({ assetsDir: realAssets, distDir: join(root, "x") }), /不自洽/);
  rmSync(stray);
  rmSync(join(realAssets, "bundles", `${bundleDigest}.bundle`));
  assert.ok(
    verifyBootstrapAssets(realAssets).some((p) => p.includes("缺失")),
    "缺失 bundle 应被报出",
  );

  console.log("bootstrap 派生 / verify / export smoke 全部通过");
} finally {
  rmSync(root, { recursive: true, force: true });
}
