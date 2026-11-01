/** ADR-034 source package schema regressions; never evaluates source. */
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";

const schema = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../../../contract/script-package.schema.json", import.meta.url)),
    "utf8",
  ),
);
const validate = new Ajv2020({ strict: true, allErrors: true }).compile(schema);
type Sample = {
  format: unknown;
  manifest: {
    sdkVersion: unknown;
    id: string;
    version: string;
    schoolId: string;
    name: string;
    network: { origins: string[]; ipAllow: string[] };
    browser: unknown;
    capabilities: [Record<string, unknown>];
    [key: string]: unknown;
  };
  source: unknown;
};
function sample(): Sample {
  return {
    format: "elecon-script/1",
    manifest: {
      sdkVersion: 1,
      id: "school.example",
      version: "0.1.0",
      schoolId: "example",
      name: "Example",
      network: {
        origins: ["https://school.example", "http://10.0.0.1:8080"],
        ipAllow: ["10.0.0.0/8", "2001:db8::/32"],
      },
      browser: false,
      capabilities: [{ id: "notice.list", schema: "elecon.notice.list", schemaVersion: "1.1" }],
    },
    source: "throw new Error('schema must not execute source');",
  };
}
for (const sdkVersion of [1, 2, 3, 4, 5, 6, 7]) {
  const p = sample();
  p.manifest.sdkVersion = sdkVersion;
  assert.equal(validate(p), true, JSON.stringify(validate.errors));
}
let rejected = 0;
for (const mutate of [
  (p: Sample) => {
    p.format = "elecon-script/2";
  },
  (p: Sample) => {
    p.manifest.sdkVersion = 8;
  },
  (p: Sample) => {
    p.manifest.version = "01.0.0";
  },
  (p: Sample) => {
    p.manifest.browser = "true";
  },
  (p: Sample) => {
    p.manifest.network.origins = ["https://*.example"];
  },
  (p: Sample) => {
    p.manifest.network.origins = ["https://school.example/path"];
  },
  (p: Sample) => {
    p.manifest.network.origins = ["https://user@school.example"];
  },
  (p: Sample) => {
    p.manifest.capabilities[0].params = {};
  },
  (p: Sample) => {
    p.manifest.capabilities[0].schema = "elecon.grades.list";
  },
  (p: Sample) => {
    p.manifest.capabilities[0].schemaVersion = "99.0";
  },
  (p: Sample) => {
    p.manifest.unknown = true;
  },
  (p: Sample) => {
    p.source = " ";
  },
]) {
  const p = sample();
  mutate(p);
  assert.equal(validate(p), false, `must reject mutation ${rejected}`);
  rejected++;
}
console.log(`script-package schema: valid source package + ${rejected} rejections passed`);

// ADR-040: SDK5 action shape is explicit; unknown SDKs remain rejected above.
const actionPackage = sample();
actionPackage.manifest.sdkVersion = 5;
actionPackage.manifest.capabilities[0] = {
  id: "climate.command",
  schema: "elecon.climate.command",
  schemaVersion: "1.0",
};
actionPackage.manifest.actions = [
  { capability: "climate.command", method: "POST", url: "https://school.example/command" },
];
assert.equal(validate(actionPackage), true, JSON.stringify(validate.errors));
actionPackage.manifest.sdkVersion = 4;
assert.equal(validate(actionPackage), false, "older SDK must reject action declarations");
