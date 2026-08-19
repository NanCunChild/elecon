import { strict as assert } from "node:assert";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  canonicalJsonBytes,
  contentDigest,
  parseBoundedZip,
  parseCanonicalJson,
  signaturePayload,
  validateManifest,
  validateSignature,
  verifySignature,
  writeDeterministicZip,
} from "./index.js";

const manifest = validateManifest({
  manifestVersion: "2.0",
  adapterId: "org.example.smoke",
  adapterVersion: "1.0.0",
  minimumAppVersion: "2.0.0",
  payload: { kind: "source", entry: "payload/source/main.js" },
  capabilities: [{ id: "test.list", emits: { schema: "test", version: "1" } }],
  files: [
    { path: "manifest.json", role: "manifest", encoding: "jcs" },
    { path: "payload/source/main.js", role: "source", encoding: "utf8" },
  ],
});
const manifestBytes = canonicalJsonBytes(manifest as never),
  source = Buffer.from("export default 1;\n");
const entries = [
  { path: "manifest.json", data: manifestBytes },
  { path: "payload/source/main.js", data: source },
];
const stored = writeDeterministicZip(entries),
  deflated = writeDeterministicZip(entries.map((x) => ({ ...x, method: 8 as const })));
const a = parseBoundedZip(stored),
  b = parseBoundedZip(deflated);
assert.equal(contentDigest(a, manifest), contentDigest(b, manifest));
const signatureExcluded = writeDeterministicZip([
  ...entries,
  { path: "META-INF/signature.json", data: Buffer.from("{}") },
]);
assert.equal(contentDigest(parseBoundedZip(signatureExcluded), manifest), contentDigest(a, manifest));
assert.throws(() => writeDeterministicZip([{ path: "../bad", data: Buffer.alloc(0) }]));
assert.throws(() => parseCanonicalJson(Buffer.from('{"a":1,"a":2}')));
const descriptor = writeDeterministicZip([{ path: "x", data: Buffer.from("x") }]);
descriptor.writeUInt16LE(8, 6);
descriptor.writeUInt16LE(8, descriptor.indexOf(Buffer.from([80, 75, 1, 2])) + 8);
assert.throws(() => parseBoundedZip(descriptor));
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const rawKey = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
const digest = contentDigest(a, manifest),
  fingerprint = createHash("sha256").update(rawKey).digest("hex");
const unsigned = {
  signatureFormat: "elecon-eleb-signature/1" as const,
  algorithm: "ed25519" as const,
  digestAlgorithm: "sha256-v1" as const,
  contentDigest: digest,
  publicKey: rawKey.toString("base64"),
  signerFingerprint: fingerprint,
  signature: "",
};
const sig = { ...unsigned, signature: sign(null, signaturePayload(unsigned), privateKey).toString("base64") };
assert.equal(verifySignature(sig), true);
assert.equal(verifySignature({ ...sig, signature: Buffer.alloc(64).toString("base64") }), false);
validateSignature(sig);
const goldenPath = fileURLToPath(new URL("../../../contract/golden/eleb/v1.json", import.meta.url));
const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as {
  contentDigest: string;
  signaturePayloadHex: string;
};
assert.equal(golden.contentDigest, digest);
assert.equal(
  golden.signaturePayloadHex,
  signaturePayload({ ...unsigned, signerFingerprint: "0".repeat(64) }).toString("hex"),
);
console.log("eleb smoke 全部通过");
