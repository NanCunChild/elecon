/**
 * release packaging smoke: fake backend only tests deterministic artifact shape.
 * Real official signing remains the interactive YubiKey CLI path.
 */

import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import type { SignBackend } from "../signer/index.js";
import { buildRelease } from "./package.js";

class FakeBackend implements SignBackend {
  readonly keyId = "test-release-key";
  async sign(): Promise<string> {
    return Buffer.alloc(64, 7).toString("base64");
  }
}

const root = mkdtempSync(join(tmpdir(), "elecon-release-"));
const adapters = join(root, "adapters");
const out = join(root, "dist");
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
    network: { allow: [] },
    capabilities: [
      {
        id: "notice.list",
        requestGraph: "declarative",
        emits: { schema: "elecon.notice.list", schemaVersion: "1.1" },
        requests: [{ key: "raw", method: "GET", url: "https://example.edu/notice" }],
      },
    ],
  }),
);
writeFileSync(join(adapter, "index.js"), "export const capabilities = {};\n");

try {
  const result = await buildRelease(
    {
      adaptersRoot: adapters,
      outputDir: out,
      baseUrl: "https://dist.example.edu/",
      sequence: 4,
      issuedAt: "2026-07-19T00:00:00Z",
      ttlSeconds: 86400,
      revocation: {
        sequence: 4,
        issuedAt: "2026-07-19T00:00:00Z",
        ttlSeconds: 86400,
        minVersions: {},
        killSwitch: false,
        entries: [],
      },
    },
    new FakeBackend(),
  );

  assert.equal(result.bundleDigests.length, 1);
  const catalogOuter = JSON.parse(
    gunzipSync(readFileSync(join(out, "catalog.json.gz"))).toString("utf8"),
  ) as { catalogJson: string; signature: string; keyId: string; algorithm: string };
  const catalog = JSON.parse(catalogOuter.catalogJson) as {
    entries: Array<{ digest: string; url: string; capabilities: string[] }>;
  };
  assert.equal(catalogOuter.keyId, "test-release-key");
  assert.equal(catalogOuter.algorithm, "ed25519");
  assert.deepEqual(catalog.entries[0]?.capabilities, ["notice.list"]);
  assert.equal(readFileSync(join(out, "bundles", `${catalog.entries[0]?.digest}.json.gz`))[0], 0x1f);
  const revocationOuter = JSON.parse(readFileSync(join(out, "revocation.json"), "utf8")) as {
    listJson: string;
  };
  assert.equal(JSON.parse(revocationOuter.listJson).sequence, 4);

  writeFileSync(join(root, "outside.txt"), "must not be signed\n");
  symlinkSync(join(root, "outside.txt"), join(adapter, "asset.txt"));
  await assert.rejects(
    () =>
      buildRelease(
        {
          adaptersRoot: adapters,
          outputDir: join(root, "dist-symlink"),
          baseUrl: "https://dist.example.edu/",
          sequence: 5,
          issuedAt: "2026-07-19T00:00:00Z",
          ttlSeconds: 86400,
          revocation: {
            sequence: 5,
            issuedAt: "2026-07-19T00:00:00Z",
            ttlSeconds: 86400,
            minVersions: {},
            killSwitch: false,
            entries: [],
          },
        },
        new FakeBackend(),
      ),
    /符号链接/,
  );
  console.log("release packaging smoke 全部通过");
} finally {
  rmSync(root, { recursive: true, force: true });
}
