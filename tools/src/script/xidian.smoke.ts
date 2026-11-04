/** Compile the real school packages and run every synthetic protocol fixture. */
import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { scanFile } from "../scanner/index.js";
import { buildXidianPackages, writeXidianPackages } from "./xidian.js";

const root = fileURLToPath(new URL("../../../school-scripts/xidian/", import.meta.url));
const first = await buildXidianPackages();
assert.equal(first.size, 2);
assert.deepEqual([...first], [...(await buildXidianPackages())]);
for (const role of ["undergraduate", "postgraduate"]) {
  const data = JSON.parse(first.get(`school-xidian-${role}.elecon.json`)!);
  assert.equal(data.manifest.version, "0.29.0");
  assert.equal(data.manifest.sdkVersion, 16);
  assert.deepEqual(data.manifest.school, {
    id: "xidian",
    name: "西安电子科技大学",
    type: { id: role, name: role === "undergraduate" ? "本科生" : "研究生" },
  });
  assert.equal(
    data.manifest.accounts.find((a: { id: string }) => a.id === "ruisi").appTunnelAccountId,
    "apptunnel",
  );
  const tunnel = data.manifest.accounts.find((a: { id: string }) => a.id === "apptunnel");
  assert.equal(tunnel.appTunnel.gatewayUrl, "https://atrust.xidian.edu.cn");
  assert.equal(tunnel.appTunnel.loginMode, "web");
  assert.equal(tunnel.appTunnel.loginDomain, "");
  assert.equal(tunnel.credentialReuse, undefined, "CAS is not the gateway's local password realm");
  assert.match(tunnel.appTunnel.nodeCertificateSha256, /^[a-f0-9]{64}$/);
  assert.equal(
    data.manifest.capabilities.find((c: { id: string }) => c.id === "forum.session").appTunnelAccountId,
    "apptunnel",
  );
  assert.ok(
    data.manifest.capabilities
      .filter((c: { id: string }) => c.id !== "forum.session")
      .every((c: { appTunnelAccountId?: string }) => c.appTunnelAccountId === undefined),
  );
  assert.deepEqual(
    data.manifest.accounts.map((account: { id: string }) => account.id),
    ["school", "ruisi", "apptunnel"],
  );
  assert.ok(!data.manifest.accounts[0].capabilities.includes("classroom.buildings"));
  assert.ok(!data.manifest.accounts[0].capabilities.some((id: string) => id.startsWith("climate.")));
  assert.deepEqual(data.manifest.accounts[1].capabilities, ["forum.session", "account.session"]);
  assert.equal(data.manifest.browser, true);
  assert.equal(data.manifest.capabilities.length, role === "undergraduate" ? 24 : 19);
  assert.equal(
    data.manifest.capabilities.find((cap: { id: string }) => cap.id === "query.controls").schemaVersion,
    "2.1",
  );
  assert.equal(
    data.manifest.capabilities.find((cap: { id: string }) => cap.id === "classroom.available").schemaVersion,
    "1.3",
  );
  assert.deepEqual(Object.keys(data.manifest.localization.messages).sort(), ["en", "fa", "ru", "uz", "zh"]);
  assert.ok(data.manifest.network.origins.includes("https://faculty.xidian.edu.cn"));
  assert.ok(data.manifest.capabilities.some((cap: { id: string }) => cap.id === "faculty.search"));
  assert.ok(data.manifest.capabilities.some((cap: { id: string }) => cap.id === "directory.phones"));
  assert.ok(data.manifest.cards.some((card: { type: string }) => card.type === "directory"));
  assert.ok(
    !data.manifest.accounts.some((account: { capabilities: string[] }) =>
      account.capabilities.includes("directory.phones"),
    ),
  );
  assert.equal(
    data.manifest.capabilities.find((cap: { id: string }) => cap.id === "schedule.week").schemaVersion,
    "1.2",
  );
  assert.equal(data.manifest.network.origins.includes("https://gxkt.juhaolian.cn"), role === "undergraduate");
  assert.equal(
    data.manifest.network.origins.includes("https://ignypt.xidian.edu.cn"),
    role === "undergraduate",
  );
  assert.equal(
    data.manifest.capabilities.some((c: { id: string }) => c.id === "climate.command"),
    role === "undergraduate",
  );
  assert.ok(data.manifest.network.origins.includes("https://xxcapp.xidian.edu.cn"));
  assert.ok(data.manifest.capabilities.some((cap: { id: string }) => cap.id === "generic.section"));
  assert.equal(data.manifest.schoolId, `xidian_${role}`);
  assert.equal(data.manifest.id, `school-xidian-${role}`);
  assert.equal(
    data.manifest.network.origins.includes("https://yjspt.xidian.edu.cn"),
    role === "postgraduate",
  );
  assert.ok(data.source.includes("MPL-2.0"));
  // The password protocol remains a separate experiment, never a hidden
  // fallback or a selectable parameter in the default school packages.
  for (const symbol of ["pdaLogin", "renderPdaInput", "encryptPda", "openSliderCaptcha.htl"])
    assert.ok(!data.source.includes(symbol), `password protocol bundled: ${symbol}`);
  assert.ok(!/^import .*from ["']\.\.?\//m.test(data.source));
}
// App assets must be regenerated with every school-source change.
for (const [name, content] of first) {
  assert.equal(
    readFileSync(join(root, "../../client/assets/school-scripts", name), "utf8"),
    content,
    `stale bundled script: ${name}`,
  );
}
for (const [asset, source] of [
  ["LICENSE.txt", "LICENSE"],
  ["RUISI-LICENSE.txt", "RUISI-LICENSE.txt"],
]) {
  assert.equal(
    readFileSync(join(root, "../../client/assets/school-scripts", asset!), "utf8"),
    readFileSync(join(root, source!), "utf8"),
  );
}
const assetDirectory = join(root, "../../client/assets/school-scripts");
for (const [, target] of readFileSync(join(assetDirectory, "README.md"), "utf8").matchAll(/\]\(([^)]+)\)/g)) {
  if (!/^(?:[a-z]+:|#)/i.test(target!)) assert.ok(existsSync(join(assetDirectory, target!)), target);
}
const out = mkdtempSync(join(tmpdir(), "elecon-xidian-build-"));
try {
  for (const name of ["school-xidian.elecon.json", "school-xidian-login.elecon.json"]) {
    writeFileSync(join(out, name), "obsolete_synthetic_package");
  }
  await writeXidianPackages(out);
  for (const [name, content] of first) assert.equal(readFileSync(join(out, name), "utf8"), content);
  assert.equal(existsSync(join(out, "school-xidian.elecon.json")), false);
  assert.equal(existsSync(join(out, "school-xidian-login.elecon.json")), false);
  for (const role of ["undergraduate", "postgraduate"]) {
    assert.equal(existsSync(join(out, `school-xidian-${role}-login.elecon.json`)), false);
  }
  const fixtures = readdirSync(join(root, "tests")).filter((name) => name.endsWith(".mjs"));
  const tests = fixtures.filter((name) => name.endsWith(".test.mjs"));
  for (const file of fixtures) {
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
  "Xidian SDK16 source packages: deterministic build, explicit trust and real module fixtures passed",
);
