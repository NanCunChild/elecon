/** ADR-043 §2.2: the native parser and packager share these presentation cases. */
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import { packageScript, ScriptPackageError } from "./package.js";

const read = (path: string) =>
  JSON.parse(readFileSync(fileURLToPath(new URL(path, import.meta.url)), "utf8"));
const fixture = read("../../../contract/golden/scripts/home-titles.json") as {
  baseManifest: Record<string, unknown>;
  cases: Array<{ name: string; valid: boolean; manifest: Record<string, unknown> }>;
};
const schema = read("../../../contract/script-package.schema.json");
const validate = new Ajv2020({ strict: true, allErrors: true }).compile(schema);
const source = "throw new Error('home titles must never evaluate source');";
for (const test of fixture.cases) {
  const manifest = { ...fixture.baseManifest, ...test.manifest };
  const input = { format: "elecon-script/1", manifest, source };
  assert.equal(validate(input), test.valid, `${test.name}: ${JSON.stringify(validate.errors)}`);
  if (test.valid) {
    const encoded = packageScript(manifest, source);
    assert.deepEqual(JSON.parse(encoded), input, test.name);
    assert.equal(packageScript(manifest, source), encoded, test.name);
  } else {
    assert.throws(() => packageScript(manifest, source), ScriptPackageError, test.name);
  }
}
console.log(`SDK7 home titles: ${fixture.cases.length} shared schema/packaging cases passed`);
