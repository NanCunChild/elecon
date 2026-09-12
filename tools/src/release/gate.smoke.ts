/**
 * 发版门 smoke（P3-08）：用本地 dev 密钥出一棵真实结构的 dist → sync 成 bootstrap → 组台账，
 * 正例通过；逐项负例（锚不符 / 过期 / kill-switch / 台账倒退与缺失 / 下次输入倒退或改内容未 bump /
 * 线上更新）必须各自被对应 G* 拦下。另对真实 trust_anchors.dart 跑一次解析。
 */

import { strict as assert } from "node:assert";
import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { signCatalog } from "../catalog/sign.js";
import { LocalDevSignBackend } from "../signer/index.js";
import { type RevocationList, signRevocation } from "../signer/revocation.js";
import { syncBootstrap } from "./bootstrap.js";
import { type GateInput, type LedgerRecordLite, parseDartTrustAnchors, runReleaseGate } from "./gate.js";
import { buildRelease } from "./package.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const root = mkdtempSync(join(tmpdir(), "elecon-gate-"));

function writeAdapter(dir: string, id: string): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "manifest.json"),
    JSON.stringify({
      manifestVersion: "1.0",
      adapterId: id,
      adapterVersion: "1.0.0",
      schoolId: id.slice("school-".length),
      displayName: "Test",
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
  writeFileSync(join(dir, "index.js"), "export const capabilities = {};\n");
  // official bundle 自 `elecon-bundle/3` 起必须携带 masker.json（ADR-026 §2.7.1）。
  writeFileSync(join(dir, "masker.json"), '{"schemaVersion":1,"rules":[]}\n');
}

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const rawHex = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
const backend = new LocalDevSignBackend(privateKey, "gate-test-key");
const anchors = new Map([["gate-test-key", rawHex]]);
const NOW = new Date("2026-09-11T12:00:00Z");

const revocation: RevocationList = {
  sequence: 2,
  issuedAt: "2026-09-11T06:31:00Z",
  ttlSeconds: 604800,
  minVersions: {},
  killSwitch: false,
  entries: [],
};

try {
  const adapters = join(root, "adapters");
  writeAdapter(join(adapters, "school-a"), "school-a");
  const dist = join(root, "dist");
  const assets = join(root, "assets");
  const release = await buildRelease(
    {
      adaptersRoot: adapters,
      outputDir: dist,
      sequence: 8,
      issuedAt: "2026-09-11T06:33:56Z",
      ttlSeconds: 86400,
      revocation,
    },
    backend,
  );
  syncBootstrap({ distDir: dist, assetsDir: assets });
  const digest = release.bundleDigests[0] as string;
  const ledger: LedgerRecordLite[] = [
    {
      adapterId: "school-a",
      adapterVersion: "1.0.0",
      bundleDigest: digest,
      catalogSequence: 8,
      revocationSequence: 2,
    },
  ];
  const rec0 = ledger[0] as LedgerRecordLite;
  const base: GateInput = { assetsDir: assets, ledger, revocationInput: revocation, anchors, now: NOW };
  const run = (over: Partial<GateInput>): ReturnType<typeof runReleaseGate> =>
    runReleaseGate({ ...base, ...over });
  const hasError = (r: ReturnType<typeof runReleaseGate>, code: string): boolean =>
    r.errors.some((e) => e.startsWith(code));

  // 正例
  {
    const r = run({});
    assert.deepEqual(r.errors, [], `正例不应有 error：${r.errors.join(" | ")}`);
    assert.equal(r.facts.catalogSequence, 8);
    console.log("  ✓ 正例通过（seq 8/2，台账一致，输入一致）");
  }
  // G1 锚不符
  {
    const r = run({ anchors: new Map([["other", rawHex]]) });
    assert.ok(hasError(r, "G1"), "keyId 不在 active 锚集合应 G1");
    const { publicKey: wrong } = generateKeyPairSync("ed25519");
    const wrongHex = wrong.export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
    assert.ok(
      hasError(run({ anchors: new Map([["gate-test-key", wrongHex]]) }), "G1"),
      "错公钥应 G1 验签失败",
    );
    console.log("  ✓ G1 锚不符 / 错公钥被拒");
  }
  // G2 过期：error 默认，warn 可降
  {
    const later = new Date("2026-09-20T00:00:00Z");
    assert.ok(hasError(run({ now: later }), "G2"), "过期 revocation 应 G2 error");
    const w = run({ now: later, staleRevocation: "warn" });
    assert.equal(w.errors.length, 0);
    assert.ok(
      w.warnings.some((x) => x.startsWith("G2")),
      "warn 模式应降为 warning",
    );
    // catalog 过 TTL 只 warn（ttl 86400，NOW+2 天但 revocation 仍在 7 天内）
    const c = run({ now: new Date("2026-09-13T12:00:00Z") });
    assert.equal(c.errors.length, 0);
    assert.ok(c.warnings.some((x) => x.includes("catalog 已过 TTL")));
    // issuedAt 超前 >5min → error
    assert.ok(hasError(run({ now: new Date("2026-09-11T06:00:00Z") }), "G2"), "issuedAt 超前应 G2");
    console.log("  ✓ G2 过期 error / warn 降级 / catalog 仅 warn / 超前拒");
  }
  // G3 kill-switch
  {
    const ks = { ...revocation, sequence: 3, killSwitch: true };
    const dist2 = join(root, "dist-ks");
    const assets2 = join(root, "assets-ks");
    await buildRelease(
      {
        adaptersRoot: adapters,
        outputDir: dist2,
        sequence: 9,
        issuedAt: "2026-09-11T07:00:00Z",
        ttlSeconds: 86400,
        revocation: ks,
      },
      backend,
    );
    syncBootstrap({ distDir: dist2, assetsDir: assets2 });
    // 同一份 adapter 字节沿用 seq 8/2 的首签记录即可（台账身份只记一次），新仪式 seq 9/3 不需要新记录。
    assert.ok(hasError(run({ assetsDir: assets2, ledger, revocationInput: ks }), "G3"), "killSwitch 应 G3");
    assert.equal(
      run({ assetsDir: assets2, ledger, revocationInput: ks, allowKillSwitch: true }).errors.length,
      0,
    );
    console.log("  ✓ G3 kill-switch 拒 / --allow-kill-switch 放行");
  }
  // G4 台账
  {
    assert.ok(hasError(run({ ledger: [{ ...rec0, catalogSequence: 9 }] }), "G4"), "台账高于 bootstrap 应 G4");
    assert.ok(hasError(run({ ledger: [] }), "G4"), "entry 未入台账应 G4");
    assert.ok(
      hasError(run({ ledger: [{ ...rec0, bundleDigest: "f".repeat(64) }] }), "G4"),
      "digest 不符应 G4",
    );
    // 首签记录早于当前 bootstrap 是常态（未变字节沿用记录），不得报错。
    assert.equal(
      run({ ledger: [{ ...rec0, catalogSequence: 5, revocationSequence: 1 }] }).errors.length,
      0,
      "早于当前的首签记录应通过",
    );
    console.log("  ✓ G4 台账高于 bootstrap / 缺失 / digest 不符被拒；早期首签记录放行");
  }
  // G5 下次输入
  {
    assert.ok(hasError(run({ revocationInput: { ...revocation, sequence: 1 } }), "G5"), "输入倒退应 G5");
    assert.ok(
      hasError(run({ revocationInput: { ...revocation, killSwitch: true } }), "G5"),
      "改内容未 bump 应 G5",
    );
    assert.equal(
      run({ revocationInput: { ...revocation, sequence: 3, killSwitch: true } }).errors.length,
      0,
      "bump 后可改内容",
    );
    console.log("  ✓ G5 输入倒退 / 改内容未 bump 被拒，bump 后放行");
  }
  // G6 线上更新
  {
    const onlineCat = await signCatalog(
      {
        catalogVersion: "1.0",
        sequence: 9,
        issuedAt: "2026-09-11T08:00:00Z",
        ttlSeconds: 86400,
        entries: [],
      },
      backend,
    );
    const onlineRev = await signRevocation({ ...revocation, sequence: 3 }, backend);
    const r = run({ online: { catalog: onlineCat, revocation: onlineRev } });
    assert.equal(
      r.errors.filter((e) => e.startsWith("G6")).length,
      2,
      "线上 catalog/revocation 都更新应各报一条 G6",
    );
    const same = run({
      online: {
        catalog: JSON.parse(readFileSync(join(assets, "catalog.json"), "utf8")),
        revocation: JSON.parse(readFileSync(join(assets, "revocation.json"), "utf8")),
      },
    });
    assert.equal(same.errors.length, 0, "线上与 bootstrap 相同应通过");
    console.log("  ✓ G6 线上更新被拒 / 相同放行");
  }
  // 真实 trust_anchors.dart 可解析且含 official 锚
  {
    const real = parseDartTrustAnchors(
      readFileSync(join(repoRoot, "client/lib/core/loader/trust_anchors.dart"), "utf8"),
    );
    assert.ok(real.has("elecon-official-ncc-1"), "应解析出 elecon-official-ncc-1");
    assert.match(real.get("elecon-official-ncc-1") as string, /^[0-9a-f]{64}$/);
    assert.throws(() => parseDartTrustAnchors("const x = 1;"), /active 锚/);
    console.log("  ✓ 真实 trust_anchors.dart 解析出 active 锚");
  }
  console.log("\n发版门 smoke 全部通过 ✅");
} finally {
  rmSync(root, { recursive: true, force: true });
}
