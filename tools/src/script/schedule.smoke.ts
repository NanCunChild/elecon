/** ADR-048/054: source package versions and exact V1 output compatibility. */
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { checkManifest, loadContract } from "../validator/index.js";
import { packageScript } from "./package.js";

const contract = loadContract();
const golden = JSON.parse(
  readFileSync(new URL("../../../contract/golden/schedule/week.json", import.meta.url), "utf8"),
);
for (const entry of golden.cases) {
  assert.equal(
    contract.schemaFor("elecon.schedule.week", entry.version)?.(entry.data),
    entry.valid,
    entry.name,
  );
}
assert.equal(contract.schemaFor("elecon.schedule.week", "2.0"), undefined);

for (const version of ["1.0", "1.1", "1.2"]) {
  const manifest = {
    sdkVersion: 6,
    id: "synthetic-schedule",
    version: "1.0.0",
    schoolId: "synthetic",
    name: "Synthetic",
    network: { origins: ["https://school.example"] },
    browser: false,
    capabilities: [{ id: "schedule.week", schema: "elecon.schedule.week", schemaVersion: version }],
    cards: [{ type: "schedule", defaultVariant: "expanded" }],
  };
  assert.ok(packageScript(manifest, "export const capabilities = {};"));
  const findings = checkManifest(
    {
      adapterId: "synthetic",
      trustTier: "official",
      network: { allow: ["https://school.example/*"] },
      capabilities: [
        {
          id: "schedule.week",
          requestGraph: "imperative",
          emits: { schema: "elecon.schedule.week", schemaVersion: version },
          params: { schema: "elecon.params.schedule.week", schemaVersion: "1.0" },
        },
      ],
    },
    contract,
  );
  assert.ok(!findings.some((f) => f.code === "C2_emits_mismatch"), version);
}
console.log("schedule schema versions, source packaging and V1 compatibility smoke passed");
