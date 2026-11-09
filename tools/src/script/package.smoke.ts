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
for (const sdkVersion of [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) {
  assert.equal(
    JSON.parse(packageScript({ ...manifest, sdkVersion }, source)).manifest.sdkVersion,
    sdkVersion,
  );
}
// SDK17 changes the runtime surface, not the package authorization format.
for (const sdkVersion of [16, 17, 18, 19, 20]) {
  assert.equal(
    JSON.parse(packageScript({ ...manifest, sdkVersion, accounts: [] }, source)).manifest.sdkVersion,
    sdkVersion,
  );
}
assert.throws(() => packageScript({ ...manifest, sdkVersion: 21, accounts: [] }, source), ScriptPackageError);
assert.equal(JSON.parse(packaged).manifest.version, "1.2.3");
assert.equal(JSON.parse(packaged).source, source);
// ADR-064: requirements are metadata, not a new credential permission grant.
const account = {
  id: "campus",
  name: "Synthetic account",
  instructions: "Sign in on the official page.",
  capabilities: ["notice.list"],
  login: { capability: "notice.list", params: { operation: "login" } },
};
const accountsManifest = { ...manifest, sdkVersion: 11, accounts: [account] };
assert.equal(JSON.parse(packageScript(accountsManifest, source)).manifest.accounts[0].id, "campus");
assert.deepEqual(
  JSON.parse(packageScript({ ...accountsManifest, accounts: [] }, source)).manifest.accounts,
  [],
);
// ADR-066: fixed account state, declaration-gated provider and distinct cards.
const sdk12 = {
  ...accountsManifest,
  sdkVersion: 12,
  capabilities: [
    ...manifest.capabilities,
    { id: "account.session", schema: "elecon.account.session", schemaVersion: "1.0" },
  ],
  accounts: [
    {
      ...account,
      status: { capability: "account.session", params: { account: "campus", operation: "status" } },
    },
  ],
  appTunnels: ["hermes-atrust"],
  cards: [
    { id: "first", type: "notice", title: "School", defaultVariant: "regular" },
    { id: "second", type: "notice", title: "Learning", defaultVariant: "regular" },
  ],
};
assert.ok(packageScript(sdk12, source));
for (const invalid of [
  { ...sdk12, sdkVersion: 11 },
  { ...sdk12, appTunnels: ["unreviewed"] },
  { ...sdk12, appTunnels: ["hermes-atrust", "hermes-atrust"] },
  { ...sdk12, cards: sdk12.cards.map((card) => ({ ...card, id: "duplicate" })) },
  {
    ...sdk12,
    cards: [
      { type: "notice", defaultVariant: "regular" },
      { type: "notice", defaultVariant: "compact" },
    ],
  },
  {
    ...sdk12,
    accounts: [
      {
        ...account,
        status: { capability: "account.session", params: { account: "other", operation: "status" } },
      },
    ],
  },
  {
    ...sdk12,
    accounts: [
      {
        ...account,
        status: { capability: "account.session", params: { account: "campus", operation: "login" } },
      },
    ],
  },
  {
    ...sdk12,
    accounts: [
      {
        ...account,
        login: { capability: "account.session", params: { account: "other", operation: "login" } },
      },
    ],
  },
  { ...sdk12, home: [{ capability: "account.session", ttlSeconds: 60, preload: true }] },
])
  assert.throws(() => packageScript(invalid, source), ScriptPackageError);
const { login: _login, ...externalAccount } = account;
assert.ok(packageScript({ ...accountsManifest, accounts: [externalAccount] }, source));
for (const invalid of [
  { ...accountsManifest, sdkVersion: 10 },
  { ...manifest, sdkVersion: 11 },
  { ...accountsManifest, accounts: null },
  { ...accountsManifest, accounts: [account, account] },
  { ...accountsManifest, accounts: [{ ...account, instructions: "a\nb" }] },
  { ...accountsManifest, accounts: [{ ...account, capabilities: ["messages.list"] }] },
  { ...accountsManifest, accounts: [{ ...account, login: { capability: "messages.session" } }] },
  {
    ...accountsManifest,
    accounts: [{ ...account, login: { ...account.login, params: { value: "汉".repeat(1400) } } }],
  },
]) {
  assert.throws(() => packageScript(invalid, source), ScriptPackageError);
}
const reordered = Object.fromEntries(Object.entries(manifest).reverse());
assert.equal(packageScript(reordered, source), packaged);
assert.equal(packageScript(manifest, source), packaged);
for (const invalid of ["", "   \n", null, 42, "abc\0def"]) {
  assert.throws(() => packageScript(manifest, invalid), ScriptPackageError);
}
for (const invalid of [
  { ...manifest, capabilities: [...manifest.capabilities, { ...manifest.capabilities[0]! }] },
  { ...manifest, version: "01.2.3" },
  { ...manifest, sdkVersion: 11 },
  { ...manifest, browser: "true" },
  { ...manifest, unknown: true },
  { ...manifest, capabilities: [{ id: "notice.list", schema: "elecon.notice.list", schemaVersion: "99.0" }] },
]) {
  assert.throws(() => packageScript(invalid, source), /script_package_manifest_invalid/);
}
for (const invalid of [
  { ...manifest, network: { origins: ["https://school.example", "https://school.example:443"] } },
  { ...manifest, network: { origins: ["https://school.example:99999"] } },
  { ...manifest, network: { origins: ["http://127.1"] } },
  { ...manifest, network: { origins: ["http://0177.0.0.1"] } },
  { ...manifest, network: { origins: ["http://0x7f000001"] } },
  { ...manifest, network: { origins: ["https://school.example."] } },
  { ...manifest, network: { origins: ["http://[::1]", "http://[0:0:0:0:0:0:0:1]"] } },
  { ...manifest, network: { origins: [], ipAllow: ["10.0.0.0/999"] } },
  { ...manifest, network: { origins: [], ipAllow: ["::/129"] } },
  { ...manifest, network: { origins: [], ipAllow: ["::/01"] } },
  { ...manifest, network: { origins: [], ipAllow: ["0127.0.0.1"] } },
  { ...manifest, name: "SYNTHETIC\0NAME" },
]) {
  assert.throws(() => packageScript(invalid, source), ScriptPackageError);
}
assert.doesNotThrow(() =>
  packageScript(
    {
      ...manifest,
      sdkVersion: 2,
      network: {
        origins: ["https://school.example", "http://10.20.0.8:8080", "https://[2001:db8::1]"],
        ipAllow: ["10.20.0.0/16", "2001:db8::/48", "::1", "0.0.0.0/0"],
      },
    },
    source,
  ),
);
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

// ADR-038: home policy semantic bounds match the native package parser.
const homeManifest = {
  ...manifest,
  sdkVersion: 4,
  home: [{ capability: "notice.list", ttlSeconds: 900, params: { nested: { page: 1 } }, preload: true }],
};
assert.doesNotThrow(() => packageScript(homeManifest, source));
for (const badHome of [
  [{ capability: "notice.list", ttlSeconds: 29 }],
  [{ capability: "grades.list", ttlSeconds: 900 }],
  [
    { capability: "notice.list", ttlSeconds: 900 },
    { capability: "notice.list", ttlSeconds: 1800 },
  ],
  [{ capability: "notice.list", ttlSeconds: 900, params: { text: "x".repeat(4096) } }],
])
  assert.throws(() => packageScript({ ...homeManifest, home: badHome }, source));
assert.throws(() => packageScript({ ...homeManifest, sdkVersion: 3 }, source));

// ADR-052: socket authorization is distinct from HTTP and sensitive home data.
const socketManifest = { ...manifest, sdkVersion: 9, websocketOrigins: ["wss://messages.example"] };
assert.doesNotThrow(() => packageScript(socketManifest, source));
for (const origins of [
  ["ws://messages.example"],
  ["wss://messages.example/path"],
  ["wss://messages.example", "wss://messages.example:443"],
])
  assert.throws(() => packageScript({ ...socketManifest, websocketOrigins: origins }, source));
assert.throws(() => packageScript({ ...socketManifest, sdkVersion: 8 }, source));
for (const id of [
  "forum.session",
  "messages.session",
  "messages.list",
  "messages.conversations",
  "messages.history",
  "messages.send",
  "attendance.checkin",
]) {
  const caps = [{ id, schema: `elecon.${id}`, schemaVersion: "1.0" }];
  assert.doesNotThrow(() => packageScript({ ...socketManifest, capabilities: caps }, source));
  assert.throws(() =>
    packageScript(
      { ...socketManifest, capabilities: caps, home: [{ capability: id, ttlSeconds: 30 }] },
      source,
    ),
  );
}

// ADR-058: shared SDK10 device-input permission admission vectors.
const deviceInputsFixture = JSON.parse(
  readFileSync(
    new URL("../../../contract/golden/scripts/device-input-permission.json", import.meta.url),
    "utf8",
  ),
);
for (const row of deviceInputsFixture.cases) {
  const candidate = { ...deviceInputsFixture.baseManifest, ...row.manifest };
  if (row.valid) assert.doesNotThrow(() => packageScript(candidate, source), row.name);
  else assert.throws(() => packageScript(candidate, source), row.name);
}
