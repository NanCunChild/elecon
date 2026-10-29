/** ADR-034 §7: package real files without evaluating source or changing versions. */
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { MAX_SCRIPT_PACKAGE_BYTES, packageScript, ScriptPackageError } from "./package.js";

const manifest = {
  sdkVersion: 1,
  id: "school.example",
  version: "1.2.3",
  schoolId: "example",
  name: "Synthetic school",
  network: { origins: ["https://school.example"] },
  browser: false,
  capabilities: [{ id: "notice.list", schema: "elecon.notice.list", schemaVersion: "1.1" }],
};
const source = "throw new Error('SYNTHETIC_SOURCE_MUST_NEVER_EXECUTE');\n";
const packaged = packageScript(manifest, source);
assert.equal(JSON.parse(packaged).manifest.version, "1.2.3");
assert.equal(JSON.parse(packaged).source, source);
const reordered = Object.fromEntries(Object.entries(manifest).reverse());
assert.equal(packageScript(reordered, source), packaged);
assert.equal(packageScript(manifest, source), packaged);
for (const invalid of ["", "   \n", null, 42, "abc\0def"]) {
  assert.throws(() => packageScript(manifest, invalid), ScriptPackageError);
}
for (const invalid of [
  { ...manifest, version: "01.2.3" },
  { ...manifest, sdkVersion: 2 },
  { ...manifest, browser: "true" },
  { ...manifest, unknown: true },
  { ...manifest, capabilities: [{ id: "notice.list", schema: "elecon.notice.list", schemaVersion: "99.0" }] },
]) {
  assert.throws(() => packageScript(invalid, source), /script_package_manifest_invalid/);
}
assert.throws(
  () => packageScript(manifest, "学".repeat(Math.floor(MAX_SCRIPT_PACKAGE_BYTES / 2))),
  /script_package_too_large/,
);

const temporary = mkdtempSync(join(tmpdir(), "elecon-script-package-"));
const manifestPath = join(temporary, "manifest.json");
const sourcePath = join(temporary, "index.js");
const outputPath = join(temporary, "example.elecon.json");
const cli = fileURLToPath(new URL("./package.ts", import.meta.url));
const run = (...args: string[]) =>
  spawnSync(process.execPath, ["--import", "tsx", cli, ...args], {
    cwd: fileURLToPath(new URL("../../", import.meta.url)),
    encoding: "utf8",
  });
const args = ["--manifest", manifestPath, "--source", sourcePath, "--out", outputPath];
try {
  writeFileSync(manifestPath, JSON.stringify(manifest));
  writeFileSync(sourcePath, source);
  const success = run(...args);
  assert.equal(success.status, 0, success.stderr);
  assert.equal(success.stdout.trim(), "script_package_created");
  assert.equal(success.stderr, "");
  assert.equal(readFileSync(outputPath, "utf8"), packaged);
  assert.equal(success.stdout.includes("SYNTHETIC"), false);

  writeFileSync(manifestPath, JSON.stringify({ ...manifest, sdkVersion: 99 }));
  const invalid = run(...args);
  assert.equal(invalid.status, 1);
  assert.equal(invalid.stderr.trim(), "script_package_manifest_invalid");
  assert.equal(readFileSync(outputPath, "utf8"), packaged, "invalid update preserves old package");
  assert.equal(invalid.stderr.includes("SYNTHETIC"), false);

  writeFileSync(manifestPath, JSON.stringify(manifest));
  writeFileSync(sourcePath, Buffer.from([0xff, 0xfe, 0x81]));
  const badUtf8 = run(...args);
  assert.equal(badUtf8.status, 1);
  assert.equal(badUtf8.stderr.trim(), "script_package_utf8_invalid");
  assert.equal(readFileSync(outputPath, "utf8"), packaged);

  writeFileSync(sourcePath, " ");
  assert.equal(run(...args).stderr.trim(), "script_package_source_invalid");
  assert.equal(readFileSync(outputPath, "utf8"), packaged);

  writeFileSync(sourcePath, source);
  assert.equal(run("--manifest", manifestPath).stderr.trim(), "script_package_usage");
  assert.equal(run(...args, "--out", "ignored").stderr.trim(), "script_package_usage");
  assert.equal(
    run("--manifest", manifestPath, "--source", sourcePath, "--out", sourcePath).stderr.trim(),
    "script_package_output_is_input",
  );
  assert.equal(readFileSync(sourcePath, "utf8"), source);
  // Direct invocation from another directory must resolve relative paths there,
  // despite an inherited INIT_CWD from a surrounding npm smoke runner.
  const repository = fileURLToPath(new URL("../../../", import.meta.url));
  const direct = spawnSync(
    process.execPath,
    [
      "--import",
      import.meta.resolve("tsx"),
      cli,
      "--manifest",
      "manifest.json",
      "--source",
      "index.js",
      "--out",
      "example.elecon.json",
    ],
    {
      cwd: temporary,
      env: { ...process.env, INIT_CWD: repository, npm_lifecycle_event: "smoke:all" },
      encoding: "utf8",
    },
  );
  assert.equal(direct.status, 0, direct.stderr);
  assert.equal(readFileSync(outputPath, "utf8"), packaged);

  // Reproduce the documented command through the actual npm workspace runner:
  // npm changes cwd to tools, while these paths are relative to the repository.
  const npmOutput = join(temporary, "npm-browser.elecon.json");
  const npm = spawnSync(
    process.platform === "win32" ? "npm.cmd" : "npm",
    [
      "run",
      "scripts:package",
      "-w",
      "tools",
      "--",
      "--manifest",
      "adapters/_template/trusted/browser/manifest.json",
      "--source",
      "adapters/_template/trusted/browser/index.js",
      "--out",
      npmOutput,
    ],
    {
      cwd: repository,
      env: { ...process.env, INIT_CWD: undefined },
      encoding: "utf8",
    },
  );
  assert.equal(npm.status, 0, npm.stderr);
  assert.match(npm.stdout, /script_package_created/);
  const browserManifest = JSON.parse(
    readFileSync(join(repository, "adapters/_template/trusted/browser/manifest.json"), "utf8"),
  );
  const browserSource = readFileSync(join(repository, "adapters/_template/trusted/browser/index.js"), "utf8");
  assert.equal(readFileSync(npmOutput, "utf8"), packageScript(browserManifest, browserSource));
  assert.deepEqual(readdirSync(temporary).sort(), [
    "example.elecon.json",
    "index.js",
    "manifest.json",
    "npm-browser.elecon.json",
  ]);
  console.log(
    "script package: deterministic source/schema/UTF8/atomic CLI and npm workspace regressions passed",
  );
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
