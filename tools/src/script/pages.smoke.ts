import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { packageScript, ScriptPackageError } from "./package.js";
const fixture = JSON.parse(readFileSync(new URL("../../../contract/golden/scripts/page-presentations.json", import.meta.url), "utf8"));
for (const test of fixture.cases) {
  const manifest = { ...fixture.baseManifest, ...test.manifest };
  if (test.valid) {
    assert.deepEqual(JSON.parse(packageScript(manifest, "export const capabilities={};")).manifest.pages, manifest.pages, test.name);
  } else {
    assert.throws(() => packageScript(manifest, "export const capabilities={};"), ScriptPackageError, test.name);
  }
}
console.log(`page presentations: ${fixture.cases.length} shared SDK18 cases passed`);
