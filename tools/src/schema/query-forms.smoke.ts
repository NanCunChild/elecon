// ADR-082/083: synthetic examples exercise versioned shapes, bounds and legacy meaning.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { packageScript, ScriptPackageError } from "../script/package.js";

const base = new URL("../../../contract/", import.meta.url);
function validator(name: string, version?: string) {
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  return ajv.compile(
    JSON.parse(
      readFileSync(
        new URL(
          version ? `schema-versions/${name}/${version}.schema.json` : `schema/${name}.schema.json`,
          base,
        ),
        "utf8",
      ),
    ),
  );
}
const form = validator("query.controls");
const root = { target: "classroom.available", title: "Synthetic query", submitLabel: "Apply" };
const make = (control: unknown) => ({ ...root, controls: [control] });
const common = { id: "schoolField", label: "School field" };
for (const control of [
  { ...common, kind: "text", initialValue: "Synthetic" },
  { ...common, kind: "number", initialValue: 0, minimum: 0, integer: true },
  { ...common, kind: "boolean", initialValue: false },
  { ...common, kind: "date", initialValue: "2026-11-04" },
  { ...common, kind: "select", initialValue: "a", options: [{ value: "a", label: "A" }] },
  { ...common, kind: "multiSelect", initialValue: ["a"], options: [{ value: "a", label: "A" }] },
  { ...common, kind: "timeRange", timeZone: "Asia/Shanghai", initialValue: { start: "09:00", end: "10:00" } },
  { ...common, kind: "select", options: [], disabled: true, disabledReason: "Choose campus first" },
])
  assert.ok(form(make(control)), JSON.stringify(form.errors));
assert.ok(form({ ...root, controls: [] }));
const deferred = make({ ...common, kind: "select", options: [], deferred: true });
assert.ok(form(deferred));
assert.equal(validator("query.controls", "2.0")(deferred), false);
assert.equal(form(make({ ...common, kind: "select", options: [], deferred: "true" })), false);
for (const control of [
  { ...common, id: "constructor", kind: "text" },
  { ...common, id: "prototype", kind: "text" },
  { ...common, kind: "number", initialValue: "5" },
  { ...common, kind: "boolean", initialValue: 0 },
  { ...common, kind: "date", initialValue: "2026-02-30" },
  { ...common, kind: "multiSelect", options: [], initialValue: ["a", "a"] },
  { ...common, kind: "timeRange", initialValue: { start: "09:00", end: "10:00" } },
  { ...common, kind: "timeRange", timeZone: "UTC", initialValue: { start: "25:00", end: "26:00" } },
  { ...common, kind: "text", parameter: "schoolId" },
  {
    ...common,
    kind: "select",
    options: Array.from({ length: 201 }, (_, i) => ({ value: String(i), label: String(i) })),
  },
])
  assert.equal(form(make(control)), false, JSON.stringify(control));
assert.equal(
  form({
    ...root,
    controls: Array.from({ length: 33 }, (_, i) => ({ ...common, id: `field${i}`, kind: "text" })),
  }),
  false,
);
const filterValues = {
  text: "Synthetic",
  number: 0,
  flag: false,
  selection: ["a"],
  time: { start: "09:00", end: "10:00" },
};
for (const name of ["params.grades.list", "params.classroom.available"]) {
  const validate = validator(name);
  assert.ok(validate({ filters: filterValues }), JSON.stringify(validate.errors));
  for (const filters of [
    { wrong: null },
    { wrong: { nested: "value" } },
    { wrong: ["a", "a"] },
    { wrong: "x".repeat(513) },
    Object.fromEntries(Array.from({ length: 33 }, (_, i) => [`field${i}`, i])),
    JSON.parse('{"__proto__":"bad"}'),
    { constructor: "bad" },
    { prototype: "bad" },
  ])
    assert.equal(validate({ filters }), false, JSON.stringify(filters));
}
const params = validator("params.query.controls");
assert.ok(params({ target: "grades.list", current: filterValues, changed: "flag" }));
assert.ok(params({ target: "grades.list", load: ["schoolField"] }));
assert.ok(params({ target: "grades.list", load: Array.from({ length: 32 }, (_, i) => `field${i}`) }));
assert.equal(
  validator("params.query.controls", "2.0")({ target: "grades.list", load: ["schoolField"] }),
  false,
);
for (const load of [
  null,
  [],
  "schoolField",
  ["same", "same"],
  ["constructor"],
  [1],
  Array.from({ length: 33 }, (_, i) => `field${i}`),
]) {
  assert.equal(params({ target: "grades.list", load }), false);
}
assert.equal(params({ target: "grades.list", current: {}, configure: true }), false);
assert.equal(validator("params.query.controls", "1.0")({ target: "grades.list", current: {} }), false);
const old = {
  ...root,
  controls: [
    {
      id: "term",
      kind: "select",
      label: "Term",
      parameter: "term",
      options: [{ value: "term-a", label: "Term A" }],
    },
  ],
};
assert.ok(validator("query.controls", "1.0")(old));
assert.equal(form(old), false);
assert.equal(validator("query.controls", "1.0")({ ...root, controls: [] }), false);
const rooms = validator("classroom.available");
const result = {
  items: [
    {
      building: "Synthetic",
      room: "101",
      roomType: { code: "seminar", label: "Seminar" },
      teachingCapacity: 0,
      examCapacity: 12,
    },
  ],
  appliedFilters: filterValues,
  coverage: { complete: true, description: "Selected building" },
};
assert.ok(rooms(result), JSON.stringify(rooms.errors));
for (const room of [{ roomType: { code: "x" } }, { teachingCapacity: -1 }, { examCapacity: 1.5 }])
  assert.equal(rooms({ items: [{ building: "Synthetic", room: "101", ...room }] }), false);
assert.equal(rooms({ ...result, coverage: { description: "Unknown" } }), false);
assert.ok(
  validator(
    "classroom.available",
    "1.2",
  )({ items: [{ building: "Synthetic", room: "101", teachingCapacity: "legacy extension" }] }),
);
assert.equal(
  rooms({ items: [{ building: "Synthetic", room: "101", teachingCapacity: "invalid standardized field" }] }),
  false,
);
// The author's real packaging path must accept the newly declared output
// versions, retain the legacy choices and reject versions with no validator.
const manifest = {
  sdkVersion: 17,
  accounts: [],
  id: "synthetic.query.forms",
  version: "1.0.0",
  schoolId: "synthetic",
  name: "Synthetic query forms",
  network: { origins: [] },
  browser: false,
};
const source = "export const capabilities = {};";
for (const [queryVersion, roomVersion] of [
  ["2.1", "1.3"],
  ["2.0", "1.3"],
  ["1.0", "1.2"],
  ["1.0", "1.1"],
]) {
  const capabilities = [
    { id: "query.controls", schema: "elecon.query.controls", schemaVersion: queryVersion },
    { id: "classroom.available", schema: "elecon.classroom.available", schemaVersion: roomVersion },
  ];
  const packaged = JSON.parse(packageScript({ ...manifest, capabilities }, source));
  assert.deepEqual(packaged.manifest.capabilities, capabilities);
  assert.equal(packaged.manifest.sdkVersion, 17);
}
for (const [id, schemaVersion] of [
  ["query.controls", "3.0"],
  ["classroom.available", "1.4"],
]) {
  assert.throws(
    () =>
      packageScript({ ...manifest, capabilities: [{ id, schema: `elecon.${id}`, schemaVersion }] }, source),
    ScriptPackageError,
  );
}
console.log(
  "query forms schemas: typed controls, bounded filters, room attributes, legacy snapshots and source packages passed",
);
