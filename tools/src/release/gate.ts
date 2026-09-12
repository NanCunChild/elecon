/**
 * 🔒 发版门（P3-08，ADR-002 §2.4 / ADR-018 §2.5）：**发出去的签名产物不得倒退、不得过期、必须入账。**
 *
 * 检查对象是 git 里唯一入库的签名产物 `client/assets/bootstrap/`（随 app 打包、也是 `dist:export`
 * 上传端点 D 的来源）。门只读、不签名、不改文件；任一 error 即非零退出。
 *
 *   G1 信任锚   catalog / revocation 的 keyId 必须命中客户端预埋 **active** 锚（直接解析
 *               `client/lib/core/loader/trust_anchors.dart`，不另存一份公钥），并以该公钥真实验签。
 *   G2 新鲜度   revocation 须在 TTL 内且 issuedAt 不超前（>5 分钟即拒）；过期 = error
 *               （`--stale-revocation=warn` 可降为 warn，供 PR CI 使用；release 工作流恒 error）。
 *               catalog 过期只 warn（客户端政策同：stale 的已签清单仍 fail-closed 倾向）。
 *   G3 kill-switch  bootstrap 的 revocation.killSwitch 为 true 时拒绝发版（会让所有装机首启即拒载），
 *               除非 `--allow-kill-switch`（密钥泄露事件下有意为之）。
 *   G4 台账     每个 catalog entry 都必须在 `release/adapter-release-ledger.json` 有**同 digest** 的记录
 *               （台账身份 = adapterId+adapterVersion，一份字节只记一次），且该记录的 catalog / revocation
 *               sequence 不得晚于 bootstrap（记录在它首次签发的那次仪式写入，之后的仪式原样沿用即可）；
 *               台账里最大的 sequence 不得高于 bootstrap（bootstrap 落后台账 = 有人签了没 sync）。
 *   G5 下次输入 `release/revocation.json`（未签名输入）sequence ≥ 已签 revocation；相等时内容须逐字段
 *               相同——内容变了却没 bump，下次仪式会签出「同序号不同内容」（2026-09-11 第一趟的错误）。
 *   G6 线上     `--online-base=` 给出时拉取线上 catalog / revocation：bootstrap 的 sequence 不得低于线上
 *               （否则发出去的 app 会被线上「回滚」）；拉不到 = error（要么不传，要么必须可达）。
 *
 * 运行：cd tools && npm run release:gate [-- --stale-revocation=warn] [--online-base=https://…/adapters/]
 */

import { createPublicKey, type KeyObject } from "node:crypto";
import { readFileSync, realpathSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { type SignedCatalog, verifyCatalog } from "../catalog/sign.js";
import type { Catalog } from "../catalog/validate.js";
import { type RevocationList, type SignedRevocationList, verifyRevocation } from "../signer/revocation.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

/** issuedAt 允许的未来时钟偏差（与客户端 catalog.dart kDefaultMaxFutureSkewMs 一致）。 */
export const MAX_FUTURE_SKEW_MS = 5 * 60 * 1000;

export interface LedgerRecordLite {
  adapterId: string;
  adapterVersion: string;
  bundleDigest: string;
  catalogSequence: number;
  revocationSequence: number;
}

export interface GateInput {
  /** bootstrap 资产目录（catalog.json / revocation.json / bundles/）。 */
  assetsDir: string;
  /** 台账记录（已由 ledger:validate 保证结构有效）。 */
  ledger: LedgerRecordLite[];
  /** 下次仪式的未签名 revocation 输入（release/revocation.json）；null = 不检查 G5。 */
  revocationInput: RevocationList | null;
  /** 客户端预埋的 **active** 信任锚：keyId → 32 字节公钥 hex。 */
  anchors: Map<string, string>;
  now: Date;
  staleRevocation?: "error" | "warn";
  allowKillSwitch?: boolean;
  /** 线上已发布的签名清单（可选；由调用方拉取）。 */
  online?: { catalog: SignedCatalog; revocation: SignedRevocationList } | null;
}

export interface GateReport {
  errors: string[];
  warnings: string[];
  facts: Record<string, string | number | boolean>;
}

const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
export function ed25519KeyFromHex(hex: string): KeyObject {
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error(`公钥 hex 须为 64 位小写 hex：${hex}`);
  return createPublicKey({
    key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(hex, "hex")]),
    format: "der",
    type: "spki",
  });
}

/**
 * 从 `trust_anchors.dart` 源码抽取 **active** 锚（keyId → publicKeyHex）。
 * 客户端 pin 是信任根的唯一权威副本；本门直接读它，避免 tools 侧再存一份可漂移的公钥。
 * 解析按 `TrustAnchor(` 字面量分段，字段顺序无关；任一 active 锚缺 keyId/publicKeyHex 即抛。
 */
export function parseDartTrustAnchors(source: string): Map<string, string> {
  const anchors = new Map<string, string>();
  // 只切**字面量**（`TrustAnchor(` 紧跟 `keyId:`），跳过类的构造器声明（`TrustAnchor({ required this.keyId …`）。
  const blocks = source.split(/TrustAnchor\(\s*(?=keyId:)/).slice(1);
  for (const block of blocks) {
    const keyId = /keyId:\s*'([^']+)'/.exec(block)?.[1];
    const hex = /publicKeyHex:\s*'([0-9a-f]{64})'/.exec(block)?.[1];
    const active = /active:\s*(true|false)/.exec(block)?.[1];
    if (keyId === undefined || hex === undefined || active === undefined) {
      throw new Error(
        `trust_anchors.dart 的 TrustAnchor 字面量缺 keyId / publicKeyHex / active：${block.slice(0, 80)}…`,
      );
    }
    if (active === "true") anchors.set(keyId, hex);
  }
  if (anchors.size === 0) throw new Error("trust_anchors.dart 未解析出任何 active 锚（fail-closed）");
  return anchors;
}

function expiry(issuedAt: string, ttlSeconds: number): number {
  return Date.parse(issuedAt) + ttlSeconds * 1000;
}

function deepEqual(a: unknown, b: unknown): boolean {
  return JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
}
function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === "object") {
    return Object.fromEntries(
      Object.keys(v as Record<string, unknown>)
        .sort()
        .map((k) => [k, sortKeys((v as Record<string, unknown>)[k])]),
    );
  }
  return v;
}

/** 门本体（纯函数，无 I/O 之外的副作用；CLI 与 smoke 共用）。 */
export function runReleaseGate(input: GateInput): GateReport {
  const errors: string[] = [];
  const warnings: string[] = [];
  const facts: GateReport["facts"] = {};
  const stale = input.staleRevocation ?? "error";
  const assets = resolve(input.assetsDir);

  // ---- G1 信任锚 + 验签
  const signedCatalog = JSON.parse(readFileSync(join(assets, "catalog.json"), "utf8")) as SignedCatalog;
  const signedRevocation = JSON.parse(
    readFileSync(join(assets, "revocation.json"), "utf8"),
  ) as SignedRevocationList;
  const verifyWithAnchor = <T>(
    what: string,
    keyId: string,
    verify: (key: KeyObject) => { ok: true; value: T } | { ok: false; reason: string },
  ): T | null => {
    const hex = input.anchors.get(keyId);
    if (hex === undefined) {
      errors.push(`G1 ${what} keyId '${keyId}' 不在客户端预埋 active 锚集合内`);
      return null;
    }
    const r = verify(ed25519KeyFromHex(hex));
    if (!r.ok) {
      errors.push(`G1 ${what} 验签失败：${r.reason}`);
      return null;
    }
    return r.value;
  };
  const catalog = verifyWithAnchor<Catalog>("catalog", signedCatalog.keyId, (k) =>
    verifyCatalog(signedCatalog, k),
  );
  const revocation = verifyWithAnchor<RevocationList>("revocation", signedRevocation.keyId, (k) =>
    verifyRevocation(signedRevocation, k),
  );
  if (catalog === null || revocation === null) return { errors, warnings, facts };
  facts.catalogSequence = catalog.sequence;
  facts.revocationSequence = revocation.sequence;
  facts.keyId = signedCatalog.keyId;

  // ---- G2 新鲜度
  const nowMs = input.now.getTime();
  const revExpiry = expiry(revocation.issuedAt, revocation.ttlSeconds);
  facts.revocationExpiresAt = new Date(revExpiry).toISOString();
  if (Date.parse(revocation.issuedAt) - nowMs > MAX_FUTURE_SKEW_MS) {
    errors.push(`G2 revocation issuedAt 超前当前时间 >5 分钟：${revocation.issuedAt}`);
  } else if (nowMs > revExpiry) {
    const msg = `G2 revocation 已过期（issuedAt ${revocation.issuedAt} + ttl ${revocation.ttlSeconds}s = ${facts.revocationExpiresAt}）；须重签后再发版`;
    (stale === "warn" ? warnings : errors).push(msg);
  }
  const catExpiry = expiry(catalog.issuedAt, catalog.ttlSeconds);
  if (Date.parse(catalog.issuedAt) - nowMs > MAX_FUTURE_SKEW_MS) {
    errors.push(`G2 catalog issuedAt 超前当前时间 >5 分钟：${catalog.issuedAt}`);
  } else if (nowMs > catExpiry) {
    warnings.push(`G2 catalog 已过 TTL（${new Date(catExpiry).toISOString()}）；客户端会在线刷新，不阻断`);
  }

  // ---- G3 kill-switch
  if (revocation.killSwitch && !input.allowKillSwitch) {
    errors.push(
      "G3 bootstrap revocation.killSwitch=true：发出去的 app 首启即拒载一切 official adapter；如属密钥泄露事件请显式 --allow-kill-switch",
    );
  }

  // ---- G4 台账
  const maxLedgerCatalog = Math.max(0, ...input.ledger.map((r) => r.catalogSequence));
  const maxLedgerRevocation = Math.max(0, ...input.ledger.map((r) => r.revocationSequence));
  if (maxLedgerCatalog > catalog.sequence) {
    errors.push(
      `G4 台账已记到 catalog sequence ${maxLedgerCatalog}，bootstrap 仍是 ${catalog.sequence}：签了没 bootstrap:sync`,
    );
  }
  if (maxLedgerRevocation > revocation.sequence) {
    errors.push(
      `G4 台账已记到 revocation sequence ${maxLedgerRevocation}，bootstrap 仍是 ${revocation.sequence}`,
    );
  }
  for (const e of catalog.entries) {
    const rec = input.ledger.find(
      (r) =>
        r.adapterId === e.adapterId && r.adapterVersion === e.adapterVersion && r.bundleDigest === e.digest,
    );
    if (!rec) {
      errors.push(
        `G4 catalog entry ${e.adapterId}@${e.adapterVersion}（${e.digest.slice(0, 12)}…）未入台账（或台账 digest 不符）`,
      );
      continue;
    }
    // 记录写于该字节首次签发的仪式；不能晚于现在这份 bootstrap（否则是从未来的台账倒推出的 bootstrap）。
    if (rec.catalogSequence > catalog.sequence || rec.revocationSequence > revocation.sequence) {
      errors.push(
        `G4 ${e.adapterId}@${e.adapterVersion} 台账记录的 sequence（catalog ${rec.catalogSequence} / revocation ${rec.revocationSequence}）晚于 bootstrap（${catalog.sequence} / ${revocation.sequence}）`,
      );
    }
  }

  // ---- G5 下次输入
  if (input.revocationInput) {
    const inp = input.revocationInput;
    if (inp.sequence < revocation.sequence) {
      errors.push(
        `G5 release/revocation.json sequence ${inp.sequence} < 已签 ${revocation.sequence}：下次仪式会签出倒退清单`,
      );
    } else if (inp.sequence === revocation.sequence && !deepEqual(inp, revocation)) {
      errors.push(`G5 release/revocation.json 内容已改但 sequence 仍为 ${inp.sequence}：内容变了必须 bump`);
    }
    facts.revocationInputSequence = inp.sequence;
  }

  // ---- G6 线上
  if (input.online) {
    const oc = verifyWithAnchor<Catalog>("线上 catalog", input.online.catalog.keyId, (k) =>
      verifyCatalog(input.online!.catalog, k),
    );
    const or = verifyWithAnchor<RevocationList>("线上 revocation", input.online.revocation.keyId, (k) =>
      verifyRevocation(input.online!.revocation, k),
    );
    if (oc && oc.sequence > catalog.sequence) {
      errors.push(
        `G6 线上 catalog sequence ${oc.sequence} > bootstrap ${catalog.sequence}：bootstrap 落后线上`,
      );
    }
    if (or && or.sequence > revocation.sequence) {
      errors.push(
        `G6 线上 revocation sequence ${or.sequence} > bootstrap ${revocation.sequence}：bootstrap 落后线上`,
      );
    }
    if (oc) facts.onlineCatalogSequence = oc.sequence;
    if (or) facts.onlineRevocationSequence = or.sequence;
  }

  return { errors, warnings, facts };
}

// ---------------- CLI ----------------

function arg(name: string): string | undefined {
  return process.argv.find((v) => v.startsWith(`--${name}=`))?.slice(name.length + 3);
}

async function fetchOnline(
  base: string,
): Promise<{ catalog: SignedCatalog; revocation: SignedRevocationList }> {
  const b = base.endsWith("/") ? base : `${base}/`;
  const get = async (name: string): Promise<Buffer> => {
    const res = await fetch(new URL(name, b), { redirect: "error", signal: AbortSignal.timeout(15_000) });
    if (!res.ok) throw new Error(`GET ${name} → HTTP ${res.status}`);
    return Buffer.from(await res.arrayBuffer());
  };
  const cat = await get("catalog.json.gz");
  const catalog = JSON.parse(
    (cat[0] === 0x1f && cat[1] === 0x8b ? gunzipSync(cat) : cat).toString("utf8"),
  ) as SignedCatalog;
  const revocation = JSON.parse((await get("revocation.json")).toString("utf8")) as SignedRevocationList;
  return { catalog, revocation };
}

async function main(): Promise<void> {
  const assetsDir = arg("assets") ?? join(repoRoot, "client/assets/bootstrap");
  const ledgerPath = arg("ledger") ?? join(repoRoot, "release/adapter-release-ledger.json");
  const inputPath = arg("revocation-input") ?? join(repoRoot, "release/revocation.json");
  const anchorsPath = arg("anchors") ?? join(repoRoot, "client/lib/core/loader/trust_anchors.dart");
  const staleArg = arg("stale-revocation") ?? "error";
  if (staleArg !== "error" && staleArg !== "warn") throw new Error("--stale-revocation 只接受 error | warn");
  const onlineBase = arg("online-base");
  const now = arg("now") ? new Date(arg("now") as string) : new Date();

  const ledger = (JSON.parse(readFileSync(ledgerPath, "utf8")) as { records: LedgerRecordLite[] }).records;
  const anchors = parseDartTrustAnchors(readFileSync(anchorsPath, "utf8"));
  const revocationInput = JSON.parse(readFileSync(inputPath, "utf8")) as RevocationList;
  let online: GateInput["online"] = null;
  if (onlineBase) {
    try {
      online = await fetchOnline(onlineBase);
    } catch (e: unknown) {
      console.error(
        `✗ G6 线上清单拉取失败（--online-base 给出即必须可达）：${e instanceof Error ? e.message : e}`,
      );
      process.exitCode = 1;
      return;
    }
  }

  const report = runReleaseGate({
    assetsDir,
    ledger,
    revocationInput,
    anchors,
    now,
    staleRevocation: staleArg,
    allowKillSwitch: process.argv.includes("--allow-kill-switch"),
    online,
  });
  for (const [k, v] of Object.entries(report.facts)) console.log(`  ${k}: ${v}`);
  for (const w of report.warnings) console.log(`⚠ ${w}`);
  for (const e of report.errors) console.error(`✗ ${e}`);
  if (report.errors.length > 0) {
    console.error(`\n发版门：${report.errors.length} 项 error，禁止发版。`);
    process.exitCode = 1;
  } else {
    console.log(`\n发版门通过（${report.warnings.length} 项 warn）。`);
  }
}

const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main().catch((e: unknown) => {
    console.error(e instanceof Error ? e.message : e);
    process.exitCode = 1;
  });
}
