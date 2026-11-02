/** ADR-047: QR-only schools and ephemeral display contract. */
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { packageScript } from "./package.js";

const manifest = {
  sdkVersion: 6,
  id: "synthetic-card",
  version: "1.0.0",
  schoolId: "synthetic",
  name: "Synthetic",
  network: { origins: ["https://school.example"] },
  browser: false,
  capabilities: [{ id: "card.qr", schema: "elecon.card.qr", schemaVersion: "1.0" }],
  cards: [{ type: "card", defaultVariant: "regular" }],
};
assert.ok(packageScript(manifest, "export const capabilities = {};"));
assert.throws(() =>
  packageScript(
    { ...manifest, home: [{ capability: "card.qr", ttlSeconds: 30, preload: false }] },
    "export const capabilities = {};",
  ),
);
const ajv = new Ajv2020({ strict: false });
(addFormats as unknown as (ajv: Ajv2020) => void)(ajv);
const validate = ajv.compile(
  JSON.parse(readFileSync(new URL("../../../contract/schema/card.qr.schema.json", import.meta.url), "utf8")),
);
const valid = {
  imageBase64: "iVBORw0KGgoAAA==",
  issuedAt: "2026-11-01T00:00:00Z",
  expiresAt: "2026-11-01T00:00:30Z",
};
assert.ok(validate(valid));
for (const change of [
  { imageBase64: "https://example.invalid/qr.png" },
  { imageBase64: "fake" },
  { expiresAt: "tomorrow" },
  { issuedAt: undefined },
])
  assert.equal(validate({ ...valid, ...change }), false);
console.log("card QR contract and package smoke passed");
