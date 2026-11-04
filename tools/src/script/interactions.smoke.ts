/** SDK14 declaration compatibility and exact resource identity. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { packageScript } from "./package.js";

const vectors = JSON.parse(
  readFileSync(new URL("../../../contract/golden/scripts/interactions.json", import.meta.url), "utf8"),
);
const source = "throw new Error('SYNTHETIC_SOURCE_MUST_NOT_EXECUTE');";
for (const row of vectors.cases) {
  const run = () => packageScript(row.manifest, source);
  if (row.valid) assert.doesNotThrow(run, row.name);
  else assert.throws(run, row.name);
}
const base = vectors.cases.find((row: { name: string }) => row.name === "bounded web template").manifest;
for (const html of ["x".repeat(262145), "学".repeat(90000), "\0"]) {
  assert.throws(() => packageScript({ ...base, webContent: [{ id: "form", title: "Form", html }] }, source));
}
assert.throws(() =>
  packageScript(
    {
      ...base,
      webContent: [0, 1, 2].map((id) => ({ id: `form${id}`, title: "Form", html: "x".repeat(180000) })),
    },
    source,
  ),
);
const before = packageScript(base, source);
const after = packageScript(
  { ...base, webContent: [{ ...base.webContent[0], html: "<p>Changed</p>" }] },
  source,
);
assert.notEqual(before, after);
console.log(`SDK14 interactions: ${vectors.cases.length} shared admission vectors and UTF8 budgets passed`);
