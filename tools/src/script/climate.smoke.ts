/** ADR-092: local device bindings have an explicit version, not a 1.0 reinterpretation. */
import { strict as assert } from "node:assert";
import { loadContract } from "../validator/index.js";
import { packageScript } from "./package.js";

const contract = loadContract();
const powerOnly = {
  items: [{ deviceId: "SYNTHETIC-DEVICE", label: "Synthetic switch", commands: ["power"] }],
};
assert.equal(contract.schemaFor("elecon.climate.devices", "1.0")?.(powerOnly), false);
assert.equal(contract.schemaFor("elecon.climate.devices", "1.1")?.(powerOnly), true);
assert.equal(contract.schemaFor("elecon.climate.devices", "1.2"), undefined);
for (const item of [
  { ...powerOnly.items[0], deviceId: "" },
  { ...powerOnly.items[0], commands: ["arbitrary"] },
  { ...powerOnly.items[0], bindingVerifiedAt: "yesterday" },
]) {
  assert.equal(contract.schemaFor("elecon.climate.devices", "1.1")?.({ items: [item] }), false);
}
for (const schemaVersion of ["1.0", "1.1"]) {
  assert.ok(packageScript({
    sdkVersion: 18,
    id: "synthetic-climate",
    schoolId: "synthetic",
    version: "1.0.0",
    name: "Synthetic",
    network: { origins: ["https://device.example.invalid"] },
    browser: false,
    accounts: [],
    capabilities: [{ id: "climate.devices", schema: "elecon.climate.devices", schemaVersion }],
  }, "export const capabilities = {};"));
}
console.log("climate binding versions, finite controls and package admission smoke passed");
