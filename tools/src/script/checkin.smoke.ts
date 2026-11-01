/** ADR-055: explicit input/output compatibility; no unversioned widening. */
import { strict as assert } from "node:assert";
import { checkManifest, loadContract } from "../validator/index.js";
import { packageScript } from "./package.js";

const contract = loadContract();
const location = {
  latitude: 12.3456,
  longitude: 45.6789,
  address: "Synthetic address",
  coordinateSystem: "service",
};
assert.equal(contract.schemaFor("elecon.params.attendance.checkin", "1.0")?.({}), true);
assert.equal(contract.schemaFor("elecon.params.attendance.checkin", "1.0")?.({ location }), false);
assert.equal(contract.schemaFor("elecon.params.attendance.checkin", "1.1")?.({ location }), true);
assert.equal(contract.schemaFor("elecon.params.attendance.checkin", "1.2"), undefined);
for (const input of [
  { location: { ...location, latitude: 91 } },
  { location: { ...location, coordinateSystem: "guessed" } },
  { qr: "synthetic-ticket" },
]) {
  assert.equal(contract.schemaFor("elecon.params.attendance.checkin", "1.1")?.(input), false);
}
for (const version of ["1.0", "1.1"]) {
  assert.equal(contract.schemaFor("elecon.attendance.checkin", version)?.({ status: "unknown" }), true);
  const cap = { id: "attendance.checkin", schema: "elecon.attendance.checkin", schemaVersion: version };
  assert.ok(
    packageScript(
      {
        sdkVersion: 9,
        id: "synthetic",
        schoolId: "synthetic",
        version: "1.0.0",
        name: "Synthetic",
        network: { origins: [] },
        browser: false,
        capabilities: [cap],
      },
      "export const capabilities={};",
    ),
  );
  const findings = checkManifest(
    {
      adapterId: "synthetic",
      trustTier: "official",
      network: { allow: [] },
      capabilities: [
        {
          id: cap.id,
          requestGraph: "imperative",
          emits: { schema: cap.schema, schemaVersion: version },
          params: { schema: "elecon.params.attendance.checkin", schemaVersion: version },
        },
      ],
    },
    contract,
  );
  assert.ok(!findings.some((f) => f.code === "C2_params_mismatch" || f.code === "C2_emits_mismatch"));
}
assert.equal(
  contract.schemaFor(
    "elecon.attendance.checkin",
    "1.1",
  )?.({ status: "rejected", reason: "unbounded raw response" }),
  false,
);
console.log("check-in input/output versions and source package admission passed");
