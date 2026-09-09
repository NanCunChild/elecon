import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import {
  type BlobTable,
  BUNDLE_FORMAT,
  type BundleEnvelope,
  type EnvelopeFileDescriptor,
  envelopeDigest,
  serializeEnvelope,
  sha256Hex,
} from "../bundle/envelope.js";
import { packBundle } from "../bundle/package.js";
import {
  CONTEXT_TAG_CATALOG,
  CONTEXT_TAG_REVOCATION,
  serializePayload,
  withContext,
} from "../signer/index.js";
import { extractLedger, LEDGER_FORMAT, validateLedger } from "./index.js";

const root = mkdtempSync(join(tmpdir(), "elecon-release-ledger-"));
try {
  const dist = join(root, "dist");
  mkdirSync(join(dist, "bundles"), { recursive: true });
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicKeyHex = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
  // digest v2：清单（descriptor）与内容（blob 表）分离；digest 只哈希 envelope 字节。
  const blobs: BlobTable = {};
  const files: EnvelopeFileDescriptor[] = [
    ["manifest.json", JSON.stringify({ adapterId: "school-example", adapterVersion: "1.2.3" })],
    ["masker.json", "{}"],
  ].map(([path, content]) => {
    const raw = Buffer.from(content!, "utf-8");
    const hash = sha256Hex(raw);
    blobs[hash] = raw;
    return { path: path!, size: raw.length, sha256: hash };
  });
  const envelope: BundleEnvelope = {
    bundleFormat: BUNDLE_FORMAT,
    adapterId: "school-example",
    adapterVersion: "1.2.3",
    files,
  };
  const envelopeBytes = serializeEnvelope(envelope);
  const digest = envelopeDigest(envelopeBytes);
  const signaturePayload = {
    adapterId: "school-example",
    adapterVersion: "1.2.3",
    tier: "official" as const,
    digest,
  };
  const signature = {
    ...signaturePayload,
    algorithm: "ed25519" as const,
    keyId: "test-key",
    signature: sign(null, serializePayload(signaturePayload), privateKey).toString("base64"),
  };
  writeFileSync(join(dist, "bundles", `${digest}.json.gz`), packBundle(envelopeBytes, signature, blobs));
  const catalogJson = JSON.stringify({
    sequence: 7,
    entries: [{ adapterId: "school-example", adapterVersion: "1.2.3", digest }],
  });
  const signedCatalog = {
    catalogJson,
    signature: sign(
      null,
      withContext(CONTEXT_TAG_CATALOG, Buffer.from(catalogJson, "utf8")),
      privateKey,
    ).toString("base64"),
    keyId: "test-key",
    algorithm: "ed25519",
  };
  writeFileSync(join(dist, "catalog.json.gz"), gzipSync(JSON.stringify(signedCatalog)));
  const listJson = JSON.stringify({ sequence: 4 });
  const signedRevocation = {
    listJson,
    signature: sign(
      null,
      withContext(CONTEXT_TAG_REVOCATION, Buffer.from(listJson, "utf8")),
      privateKey,
    ).toString("base64"),
    keyId: "test-key",
    algorithm: "ed25519",
  };
  writeFileSync(join(dist, "revocation.json"), JSON.stringify(signedRevocation));

  const draft = extractLedger({ dist, keyId: "test-key", publicKeyHex });
  assert.equal(draft.records[0]?.status, "incomplete");
  assert.deepEqual(draft.records[0]?.missingFacts, ["sourceCommit", "signedAt", "signer", "reviewReference"]);
  assert.equal(validateLedger(draft).length, 0);

  const complete = extractLedger({
    dist,
    keyId: "test-key",
    publicKeyHex,
    sourceCommit: "a".repeat(40),
    signedAt: "2026-08-05T12:00:00Z",
    signer: "release-owner",
    reviewReference: "https://example.invalid/review/1",
  });
  assert.equal(complete.format, LEDGER_FORMAT);
  assert.equal(complete.records[0]?.status, "complete");
  assert.match(complete.records[0]?.policy.digest ?? "", /^[0-9a-f]{64}$/);

  const invalid = structuredClone(complete);
  invalid.records[0]!.sourceCommit = null;
  assert(validateLedger(invalid).some((error) => error.includes("sourceCommit is null")));

  const rollback = structuredClone(complete);
  rollback.records.push({
    ...structuredClone(complete.records[0]!),
    catalogSequence: 6,
    bundleDigest: "b".repeat(64),
  });
  assert(validateLedger(rollback).some((error) => error.includes("catalogSequence rolls back")));

  const equivocation = structuredClone(complete);
  equivocation.records.push({
    ...structuredClone(complete.records[0]!),
    bundleDigest: "b".repeat(64),
  });
  assert(
    validateLedger(equivocation).some((error) => error.includes("duplicates or equivocates")),
    "same adapterId+version with another digest must be rejected",
  );

  const { publicKey: wrongPublicKey } = generateKeyPairSync("ed25519");
  const wrongPublicKeyHex = wrongPublicKey
    .export({ format: "der", type: "spki" })
    .subarray(-32)
    .toString("hex");
  assert.throws(
    () => extractLedger({ dist, keyId: "test-key", publicKeyHex: wrongPublicKeyHex }),
    /catalog verification failed/,
  );

  const forgedSignature = { ...signature, signature: Buffer.alloc(64).toString("base64") };
  writeFileSync(
    join(dist, "bundles", `${digest}.json.gz`),
    packBundle(envelopeBytes, forgedSignature, blobs),
  );
  assert.throws(() => extractLedger({ dist, keyId: "test-key", publicKeyHex }), /bundle verification failed/);
  assert.throws(
    () => extractLedger({ dist, keyId: "other-key", publicKeyHex }),
    /operator-supplied trusted keyId/,
  );

  writeFileSync(join(dist, "bundles", `${digest}.json.gz`), packBundle(envelopeBytes, signature, blobs));
  writeFileSync(
    join(dist, "catalog.json.gz"),
    gzipSync(JSON.stringify({ ...signedCatalog, signature: Buffer.alloc(64).toString("base64") })),
  );
  assert.throws(
    () => extractLedger({ dist, keyId: "test-key", publicKeyHex }),
    /catalog verification failed/,
  );

  writeFileSync(join(dist, "catalog.json.gz"), gzipSync(JSON.stringify(signedCatalog)));
  writeFileSync(
    join(dist, "revocation.json"),
    JSON.stringify({ ...signedRevocation, signature: Buffer.alloc(64).toString("base64") }),
  );
  assert.throws(
    () => extractLedger({ dist, keyId: "test-key", publicKeyHex }),
    /revocation verification failed/,
  );
  console.log(
    "release ledger smoke: real signatures, trusted key pinning, equivocation, and rollback passed",
  );
} finally {
  rmSync(root, { recursive: true, force: true });
}
