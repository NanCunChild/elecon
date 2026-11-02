/** ADR-052: deterministic enhancement packages and offline protocol fixtures. */
import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { buildChaoxingPackages } from "./chaoxing.js";

const root = fileURLToPath(new URL("../../../", import.meta.url));
const first = await buildChaoxingPackages();
assert.ok(!readdirSync(`${root}/client/assets/school-scripts`).some((name) => /chaoxing/i.test(name)));
assert.equal(first.size, 2);
assert.deepEqual([...first], [...(await buildChaoxingPackages())]);
for (const [name, content] of first) {
  const p = JSON.parse(content);
  assert.equal(p.manifest.sdkVersion, 12);
  assert.equal(p.manifest.version, "0.5.1");
  assert.equal(
    p.manifest.capabilities.find((c: { id: string }) => c.id === "attendance.checkin").schemaVersion,
    "1.1",
  );
  assert.equal(p.manifest.scanner, true);
  assert.deepEqual(
    p.manifest.capabilities.map((c: { id: string }) => c.id),
    [
      "messages.session",
      "messages.list",
      "messages.conversations",
      "messages.history",
      "messages.send",
      "attendance.checkin",
      "notice.list",
      "account.session",
    ],
  );
  assert.deepEqual(p.manifest.websocketOrigins, ["wss://im-api-wechat-vip6.easemob.com"]);
  assert.deepEqual(p.manifest.home, [{ capability: "notice.list", ttlSeconds: 300, preload: true }]);
  assert.deepEqual(p.manifest.cards, [
    {
      id: "learning-notices",
      type: "notice",
      title: "学习通知",
      defaultVariant: "regular",
    },
  ]);
  assert.equal(p.manifest.id, `enhancement-${p.manifest.schoolId.replaceAll("_", "-")}-chaoxing`);
  if (p.manifest.schoolId === "xidian_undergraduate") {
    assert.equal(readFileSync(`${root}/client/test/fixtures/community/${name}`, "utf8"), content);
  }
}
execFileSync(
  process.execPath,
  [
    "--test",
    `${root}/school-scripts/xidian-chaoxing/tests/community.test.mjs`,
    `${root}/school-scripts/xidian-chaoxing/tests/chat.test.mjs`,
    `${root}/school-scripts/xidian-chaoxing/tests/notices.test.mjs`,
  ],
  { stdio: "pipe" },
);
console.log("chaoxing packages and synthetic protocol fixtures passed");
