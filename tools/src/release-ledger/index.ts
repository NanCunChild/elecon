/**
 * 🔒 Release-ledger extraction accepts records only after pinned Ed25519 verification of the
 * catalog, revocation list, and every bundle (ADR-018 §2.5/§2.9; 红线 #4).
 */
import { createHash, createPublicKey, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { fileBytesByPath } from "../bundle/envelope.js";
import { openBundle } from "../bundle/package.js";
import { type SignedCatalog, verifyCatalog } from "../catalog/sign.js";
import { type SignedRevocationList, verifyRevocation } from "../signer/revocation.js";

export const LEDGER_FORMAT = "elecon-adapter-release-ledger/v1";
const repoRoot = resolve(fileURLToPath(new URL("../../../", import.meta.url)));

const missingFactNames = ["sourceCommit", "signedAt", "signer", "reviewReference"] as const;
type MissingFact = (typeof missingFactNames)[number];

export interface ReleaseLedgerRecord {
  status: "complete" | "incomplete";
  adapterId: string;
  adapterVersion: string;
  sourceCommit: string | null;
  bundleDigest: string;
  policy: { included: boolean; digest: string | null };
  catalogSequence: number;
  revocationSequence: number;
  keyId: string;
  signedAt: string | null;
  signer: string | null;
  reviewReference: string | null;
  missingFacts: MissingFact[];
}

export interface ReleaseLedger {
  format: typeof LEDGER_FORMAT;
  records: ReleaseLedgerRecord[];
}

const recordKeys = new Set([
  "status",
  "adapterId",
  "adapterVersion",
  "sourceCommit",
  "bundleDigest",
  "policy",
  "catalogSequence",
  "revocationSequence",
  "keyId",
  "signedAt",
  "signer",
  "reviewReference",
  "missingFacts",
]);
const digestPattern = /^[0-9a-f]{64}$/;
const commitPattern = /^[0-9a-f]{40}$/;
const rfc3339Pattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.trim() === value && value.length > 0;
}

function sequence(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

export function validateLedger(value: unknown): string[] {
  const errors: string[] = [];
  if (!isObject(value)) return ["ledger must be a JSON object"];
  for (const key of Object.keys(value)) {
    if (key !== "format" && key !== "records") errors.push(`ledger has unknown field: ${key}`);
  }
  if (value.format !== LEDGER_FORMAT) errors.push(`format must be ${LEDGER_FORMAT}`);
  if (!Array.isArray(value.records)) return [...errors, "records must be an array"];

  let previousCatalog = -1;
  let previousRevocation = -1;
  const identities = new Set<string>();
  for (const [index, raw] of value.records.entries()) {
    const at = `records[${index}]`;
    if (!isObject(raw)) {
      errors.push(`${at} must be an object`);
      continue;
    }
    for (const key of Object.keys(raw)) {
      if (!recordKeys.has(key)) errors.push(`${at} has unknown field: ${key}`);
    }
    if (raw.status !== "complete" && raw.status !== "incomplete") {
      errors.push(`${at}.status must be complete or incomplete`);
    }
    for (const field of ["adapterId", "adapterVersion", "keyId"] as const) {
      if (!nonEmpty(raw[field])) errors.push(`${at}.${field} must be a non-empty trimmed string`);
    }
    if (!nonEmpty(raw.bundleDigest) || !digestPattern.test(raw.bundleDigest)) {
      errors.push(`${at}.bundleDigest must be 64 lowercase hex characters`);
    }
    if (!sequence(raw.catalogSequence))
      errors.push(`${at}.catalogSequence must be a non-negative safe integer`);
    if (!sequence(raw.revocationSequence)) {
      errors.push(`${at}.revocationSequence must be a non-negative safe integer`);
    }

    if (!isObject(raw.policy)) {
      errors.push(`${at}.policy must be an object`);
    } else {
      for (const key of Object.keys(raw.policy)) {
        if (key !== "included" && key !== "digest") errors.push(`${at}.policy has unknown field: ${key}`);
      }
      if (typeof raw.policy.included !== "boolean") errors.push(`${at}.policy.included must be boolean`);
      if (raw.policy.included === true) {
        if (!nonEmpty(raw.policy.digest) || !digestPattern.test(raw.policy.digest)) {
          errors.push(`${at}.policy.digest must be 64 lowercase hex characters when included`);
        }
      } else if (raw.policy.included === false && raw.policy.digest !== null) {
        errors.push(`${at}.policy.digest must be null when no policy is included`);
      }
    }

    const missing = new Set<MissingFact>();
    if (!Array.isArray(raw.missingFacts)) {
      errors.push(`${at}.missingFacts must be an array`);
    } else {
      for (const fact of raw.missingFacts) {
        if (!missingFactNames.includes(fact as MissingFact)) {
          errors.push(`${at}.missingFacts contains unknown fact: ${String(fact)}`);
        } else if (missing.has(fact as MissingFact)) {
          errors.push(`${at}.missingFacts contains duplicate fact: ${String(fact)}`);
        } else {
          missing.add(fact as MissingFact);
        }
      }
    }

    const nullableFacts: Array<[MissingFact, unknown, (candidate: string) => boolean]> = [
      ["sourceCommit", raw.sourceCommit, (candidate) => commitPattern.test(candidate)],
      [
        "signedAt",
        raw.signedAt,
        (candidate) => rfc3339Pattern.test(candidate) && !Number.isNaN(Date.parse(candidate)),
      ],
      ["signer", raw.signer, () => true],
      ["reviewReference", raw.reviewReference, () => true],
    ];
    for (const [fact, factValue, valid] of nullableFacts) {
      if (factValue === null) {
        if (!missing.has(fact)) errors.push(`${at}.${fact} is null but missingFacts does not name it`);
      } else if (!nonEmpty(factValue) || !valid(factValue)) {
        errors.push(`${at}.${fact} has an invalid value`);
      } else if (missing.has(fact)) {
        errors.push(`${at}.${fact} is present but missingFacts names it`);
      }
    }
    if (raw.status === "complete" && missing.size > 0) errors.push(`${at} is complete but has missing facts`);
    if (raw.status === "incomplete" && missing.size === 0)
      errors.push(`${at} is incomplete but has no missing facts`);

    if (sequence(raw.catalogSequence)) {
      if (raw.catalogSequence < previousCatalog) errors.push(`${at}.catalogSequence rolls back`);
      previousCatalog = raw.catalogSequence;
    }
    if (sequence(raw.revocationSequence)) {
      if (raw.revocationSequence < previousRevocation) errors.push(`${at}.revocationSequence rolls back`);
      previousRevocation = raw.revocationSequence;
    }
    if (nonEmpty(raw.adapterId) && nonEmpty(raw.adapterVersion)) {
      const identity = `${raw.adapterId}\0${raw.adapterVersion}`;
      if (identities.has(identity)) {
        errors.push(`${at} duplicates or equivocates an earlier adapterId+adapterVersion`);
      }
      identities.add(identity);
    }
  }
  return errors;
}

interface CatalogBody {
  sequence: number;
  entries: Array<{ adapterId: string; adapterVersion: string; digest: string }>;
}

export interface ExtractOptions {
  dist: string;
  keyId: string;
  publicKeyHex: string;
  sourceCommit?: string;
  signedAt?: string;
  signer?: string;
  reviewReference?: string;
}

function trustedEd25519Key(publicKeyHex: string): KeyObject {
  if (!/^[0-9a-fA-F]{64}$/.test(publicKeyHex)) {
    throw new Error("public key must be exactly 32 bytes encoded as 64 hex characters");
  }
  // RFC 8410 SubjectPublicKeyInfo prefix for a raw 32-byte Ed25519 public key.
  const spkiPrefix = Buffer.from("302a300506032b6570032100", "hex");
  return createPublicKey({
    key: Buffer.concat([spkiPrefix, Buffer.from(publicKeyHex, "hex")]),
    format: "der",
    type: "spki",
  });
}

export function extractLedger(options: ExtractOptions): ReleaseLedger {
  if (!nonEmpty(options.keyId)) throw new Error("trusted keyId must be a non-empty trimmed string");
  const publicKey = trustedEd25519Key(options.publicKeyHex);
  const dist = resolve(options.dist);
  const catalogOuter = JSON.parse(
    gunzipSync(readFileSync(resolve(dist, "catalog.json.gz"))).toString("utf8"),
  ) as SignedCatalog;
  const revocationOuter = JSON.parse(
    readFileSync(resolve(dist, "revocation.json"), "utf8"),
  ) as SignedRevocationList;
  if (catalogOuter.keyId !== options.keyId || revocationOuter.keyId !== options.keyId) {
    throw new Error("catalog and revocation keyId must match the operator-supplied trusted keyId");
  }
  const verifiedCatalog = verifyCatalog(catalogOuter, publicKey);
  if (!verifiedCatalog.ok) throw new Error(`catalog verification failed: ${verifiedCatalog.reason}`);
  const catalog = verifiedCatalog.value as CatalogBody;
  const verifiedRevocation = verifyRevocation(revocationOuter, publicKey);
  if (!verifiedRevocation.ok) {
    throw new Error(`revocation verification failed: ${verifiedRevocation.reason}`);
  }
  const revocation = verifiedRevocation.value;

  const records = catalog.entries.map((entry): ReleaseLedgerRecord => {
    const bundlePath = resolve(dist, "bundles", `${entry.digest}.json.gz`);
    const bundle = readFileSync(bundlePath); // 原始 .json.gz 字节；解析全在 openBundle 内（验签先于解析）
    // digest v2：openBundle 走完 §2.9.1 的 1–11 步（含 Ed25519 验签、卫生闸门、blob 集合
    // 精确相等、身份三方一致）。台账只记录**验签通过**的产物——这是它作为审计源的前提。
    const opened = openBundle(bundle, publicKey);
    if (!opened.ok) {
      throw new Error(`${entry.adapterId} bundle verification failed: ${opened.reason}`);
    }
    const { envelope, blobs, signature: bundleSignature } = opened.value;
    const digest = bundleSignature.digest;
    if (
      digest !== entry.digest ||
      envelope.adapterId !== entry.adapterId ||
      envelope.adapterVersion !== entry.adapterVersion
    ) {
      throw new Error(`${entry.adapterId} catalog, bundle identity, or digest differ`);
    }
    if (bundleSignature.keyId !== catalogOuter.keyId) {
      throw new Error(`${entry.adapterId} bundle keyId differs from catalog keyId`);
    }
    const identity = { adapterId: envelope.adapterId, adapterVersion: envelope.adapterVersion };
    const policyBytes = fileBytesByPath(envelope, blobs, "masker.json");
    const missingFacts = missingFactNames.filter((fact) => options[fact] === undefined);
    return {
      status: missingFacts.length === 0 ? "complete" : "incomplete",
      adapterId: identity.adapterId,
      adapterVersion: identity.adapterVersion,
      sourceCommit: options.sourceCommit ?? null,
      bundleDigest: digest,
      policy: policyBytes
        ? { included: true, digest: createHash("sha256").update(policyBytes).digest("hex") }
        : { included: false, digest: null },
      catalogSequence: catalog.sequence,
      revocationSequence: revocation.sequence,
      keyId: catalogOuter.keyId,
      signedAt: options.signedAt ?? null,
      signer: options.signer ?? null,
      reviewReference: options.reviewReference ?? null,
      missingFacts,
    };
  });
  const ledger: ReleaseLedger = { format: LEDGER_FORMAT, records };
  const errors = validateLedger(ledger);
  if (errors.length > 0) throw new Error(`extracted ledger is invalid:\n${errors.join("\n")}`);
  return ledger;
}

function arg(name: string): string | undefined {
  const prefix = `--${name}=`;
  return process.argv.find((value) => value.startsWith(prefix))?.slice(prefix.length);
}

function hasFlag(name: string): boolean {
  return process.argv.includes(`--${name}`);
}

function main(): void {
  const command = process.argv[2];
  if (command === "validate") {
    const ledgerArg = arg("ledger") ?? "release/adapter-release-ledger.json";
    const path = isAbsolute(ledgerArg) ? ledgerArg : resolve(repoRoot, ledgerArg);
    const ledger = JSON.parse(readFileSync(path, "utf8")) as unknown;
    const errors = validateLedger(ledger);
    if (errors.length > 0) throw new Error(errors.join("\n"));
    const validLedger = ledger as ReleaseLedger;
    const incomplete = validLedger.records.filter((record) => record.status !== "complete").length;
    const historicallyComplete = validLedger.records.length > 0 && incomplete === 0;
    if (hasFlag("require-complete") && !historicallyComplete) {
      throw new Error(
        validLedger.records.length === 0
          ? "release ledger is structurally valid but historical completeness is not established: no records"
          : `release ledger is structurally valid but historically incomplete: ${incomplete} incomplete record(s)`,
      );
    }
    console.log(`release ledger structurally valid: ${path}`);
    console.log(
      historicallyComplete
        ? `historical completeness: complete (${validLedger.records.length} record(s))`
        : validLedger.records.length === 0
          ? "historical completeness: not established (ledger has no records)"
          : `historical completeness: incomplete (${incomplete} of ${validLedger.records.length} record(s))`,
    );
    return;
  }
  if (command === "extract") {
    const dist = arg("dist");
    if (!dist) throw new Error("extract requires --dist=<signed-dist>");
    const keyId = arg("key-id");
    if (!keyId) throw new Error("extract requires --key-id=<trusted-key-id>");
    const publicKeyHex = arg("public-key-hex");
    if (!publicKeyHex) throw new Error("extract requires --public-key-hex=<32-byte-raw-ed25519-key>");
    const ledger = extractLedger({
      dist: isAbsolute(dist) ? dist : resolve(repoRoot, dist),
      keyId,
      publicKeyHex,
      sourceCommit: arg("source-commit"),
      signedAt: arg("signed-at"),
      signer: arg("signer"),
      reviewReference: arg("review-reference"),
    });
    process.stdout.write(`${JSON.stringify(ledger, null, 2)}\n`);
    return;
  }
  throw new Error(
    "usage: release-ledger validate [--ledger=...] [--require-complete] | extract --dist=... --key-id=... --public-key-hex=...",
  );
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  try {
    main();
  } catch (error) {
    console.error((error as Error).message);
    process.exitCode = 1;
  }
}
