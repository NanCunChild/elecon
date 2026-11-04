/** ADR-070: packaging and installation share the same resource admission cases. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { packageScript } from "./package.js";

const source = "throw new Error('SYNTHETIC_SOURCE_MUST_NOT_EXECUTE');";
const base = {
  sdkVersion: 13,
  id: "localization-example",
  schoolId: "example",
  version: "1.0.0",
  name: "Synthetic",
  network: { origins: [] },
  browser: false,
  accounts: [],
  capabilities: [{ id: "generic.section", schema: "elecon.generic.section", schemaVersion: "1.0" }],
};
const vectors = JSON.parse(
  readFileSync(new URL("../../../contract/golden/scripts/localization.json", import.meta.url), "utf8"),
);
for (const vector of vectors.cases) {
  const manifest = { ...base, sdkVersion: vector.sdkVersion, localization: vector.localization };
  if (vector.valid) assert.doesNotThrow(() => packageScript(manifest, source), vector.name);
  else assert.throws(() => packageScript(manifest, source), vector.name);
}
const localization = { defaultLocale: "en", messages: { en: { title: "Example" } } };
assert.ok(packageScript(base, source), "SDK13 does not force localization");
assert.ok(packageScript({ ...base, localization }, source));
const controls = {
  ...base,
  capabilities: [{ id: "query.controls", schema: "elecon.query.controls", schemaVersion: "1.0" }],
};
assert.ok(packageScript(controls, source));
assert.throws(() =>
  packageScript({ ...controls, home: [{ capability: "query.controls", ttlSeconds: 60 }] }, source),
);
for (const messages of [
  { en: Object.fromEntries(Array.from({ length: 1025 }, (_, n) => [`key${n}`, "x"])) },
  { en: { title: "x".repeat(4097) } },
  { en: Object.fromEntries(Array.from({ length: 100 }, (_, n) => [`key${n}`, "学".repeat(1000)])) },
  Object.fromEntries(
    Array.from({ length: 33 }, (_, n) => [`en-${String(n).padStart(3, "0")}`, { title: "x" }]),
  ),
]) {
  const defaultLocale = Object.keys(messages)[0];
  assert.throws(() => packageScript({ ...base, localization: { defaultLocale, messages } }, source));
}
assert.ok(
  packageScript(
    { ...base, localization: { defaultLocale: "en", messages: { en: { title: "🎒".repeat(4096) } } } },
    source,
  ),
);

const template = new URL("../../../adapters/_template/trusted/localized/", import.meta.url);
const templateManifest = JSON.parse(readFileSync(new URL("manifest.json", template), "utf8"));
const templateSource = readFileSync(new URL("index.js", template), "utf8");
assert.ok(packageScript(templateManifest, templateSource));
console.log(
  "SDK13 localization: shared admission vectors, resource budgets and author-selected template passed",
);
