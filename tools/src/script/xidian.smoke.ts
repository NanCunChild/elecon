/** Compile the real school packages and run every synthetic protocol fixture. */
import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { scanFile } from "../scanner/index.js";
import { buildXidianPackages, writeXidianPackages } from "./xidian.js";

const root = fileURLToPath(new URL("../../../school-scripts/xidian/", import.meta.url));
const first = await buildXidianPackages();
assert.equal(first.size, 2);
assert.deepEqual([...first], [...(await buildXidianPackages())]);
const data = JSON.parse(first.get("school-xidian.elecon.json")!);
const login = JSON.parse(first.get("school-xidian-login.elecon.json")!);
assert.equal(data.manifest.version, "0.6.0");
assert.equal(data.manifest.sdkVersion, 2);
assert.equal(data.manifest.browser, false);
assert.equal(data.manifest.capabilities.length, 11);
assert.equal(login.manifest.browser, true);
assert.equal(login.manifest.schoolId, data.manifest.schoolId);
assert.ok(data.source.includes("MPL-2.0"));
assert.ok(!/^import .*from ["']\.\.?\//m.test(data.source));
const out = mkdtempSync(join(tmpdir(), "elecon-xidian-build-"));
try {
  await writeXidianPackages(out);
  for (const [name, content] of first) assert.equal(readFileSync(join(out, name), "utf8"), content);
  const tests = readdirSync(join(root, "tests")).filter((name) => name.endsWith(".test.mjs"));
  for (const file of tests) {
    assert.deepEqual(
      scanFile(join(root, "tests", file)).filter((finding) => finding.level === "error"),
      [],
      `PII fixture check: ${file}`,
    );
  }
  const result = execFileSync(
    process.execPath,
    ["--test", ...tests.map((name) => join(root, "tests", name))],
    { encoding: "utf8" },
  );
  assert.ok(!result.includes("✖"));
  console.log(result.trim());
} finally {
  rmSync(out, { recursive: true, force: true });
}
console.log(
  "Xidian SDK2 source packages: deterministic build, explicit trust and real module fixtures passed",
);
