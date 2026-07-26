import { strict as assert } from "node:assert";
import { adapterDirIfPresent } from "./smoke-utils.js";

assert.strictEqual(adapterDirIfPresent("/definitely-missing-elecon-root/", "school-missing", false), null);
assert.throws(
  () => adapterDirIfPresent("/definitely-missing-elecon-root/", "school-missing", true),
  /缺必需 adapter 'school-missing'/,
);

console.log("smoke-utils smoke: adapter presence policy passed");
