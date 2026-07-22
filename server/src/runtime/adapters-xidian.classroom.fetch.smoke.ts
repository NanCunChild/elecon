/**
 * school-xidian classroom.buildings / classroom.available 凭据注入 smoke。
 * 使用公开仓 adapter + fake transport，不访问真实 IDS/校园网。
 * 运行：cd server && npm run smoke:xidian-classroom
 */
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import {
  adapterDirIfPresent,
  FakeResolver,
  FakeTransport,
  readText,
  resolveRepoRoot,
  resp,
  runMain,
  skipSmoke,
} from "./__testutils__/smoke-utils.js";
import type { BrokerManifestView } from "./broker/inject-policy.js";
import { runFetchAdapter } from "./sandbox.js";
import { TrustedAdapterContext } from "./trusted-context.js";

const repoRoot = resolveRepoRoot(import.meta.url);

const BUILDING_ROWS = [
  { JXLDM: "BLDG-A", JXLJC: "示例教学楼A", XXXQMC: "示例校区" },
  { JXLDM: "BLDG-B", JXLJC: "示例教学楼B", XXXQMC: "示例校区" },
];

const CLASSROOM_ROWS = [
  {
    JASMC: "A101",
    JASDM: "ROOM-A101",
    LC: "1",
    JC1: "0_",
    JC2: "0_",
    JC3: "0_",
    JC4: "0_",
    JC5: "1_",
    JC6: "1_",
    JC7: "0_",
    JC8: "0_",
    JC9: "0_",
    JC10: "0_",
    JC11: "0_",
  },
  {
    JASMC: "A102",
    JASDM: "ROOM-A102",
    LC: "1",
    JC1: "1_",
    JC2: "1_",
    JC3: "0_",
    JC4: "0_",
    JC5: "0_",
    JC6: "0_",
    JC7: "0_",
    JC8: "0_",
    JC9: "0_",
    JC10: "0_",
    JC11: "0_",
  },
];

function ehallView(): BrokerManifestView {
  return {
    allow: ["https://ehall.xidian.edu.cn/*"],
    credentials: { "ehall-session": { scope: ["https://ehall.xidian.edu.cn/*"], type: "cookie" } },
  };
}

function compileSchema(path: string) {
  const schema = JSON.parse(readFileSync(path, "utf8"));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv.compile(schema);
}

async function smokeBuildings(source: string): Promise<void> {
  const transport = new FakeTransport([
    resp({ status: 302, location: "https://ehall.xidian.edu.cn/new/index.html", body: "" }),
    resp({ status: 200, headers: { "content-type": "text/html" }, body: "<html>app</html>" }),
    resp({
      status: 200,
      headers: { "content-type": "application/json", "set-cookie": "JSESSIONID=ROTATED" },
      setCookie: ["JSESSIONID=ROTATED; Path=/; Secure"],
      body: JSON.stringify({ datas: { jxlcx: { rows: BUILDING_ROWS } } }),
    }),
  ]);

  const { data } = await runFetchAdapter(
    { source, capability: "classroom.buildings", params: {}, nowMs: 1_700_000_000_000 },
    {
      trust: TrustedAdapterContext.devSideload(),
      view: ehallView(),
      resolver: new FakeResolver({ "ehall-session": { via: "cookie", value: "JSESSIONID=INITIAL" } }),
      transport,
    },
  );

  assert.equal(transport.seen.length, 3, "应请求 appShow、应用入口和 jxlcx");
  assert.equal(transport.seen[2]!.headers.Cookie, "JSESSIONID=INITIAL", "教学楼请求应注入 cookie");
  assert.match(transport.seen[2]!.url, /jxlcx\.do/, "应命中 jxlcx");
  assert.equal(transport.seen[2]!.headers["Set-Cookie"], undefined, "adapter 不应控制 Set-Cookie");

  const validate = compileSchema(`${repoRoot}contract/schema/classroom.buildings.schema.json`);
  assert.ok(validate(data), `buildings 产出未通过 schema：${JSON.stringify(validate.errors)}`);
  assert.deepEqual(data, {
    items: [
      { building: "示例教学楼A", buildingId: "BLDG-A", campus: "示例校区" },
      { building: "示例教学楼B", buildingId: "BLDG-B", campus: "示例校区" },
    ],
  });
  console.log("school-xidian classroom.buildings：凭证注入 + schema 通过 ✅");
}

async function smokeAvailable(source: string): Promise<void> {
  // openApp(2) + jxlcx + rqzhzcjc + cxjsqk
  const transport = new FakeTransport([
    resp({ status: 302, location: "https://ehall.xidian.edu.cn/new/index.html", body: "" }),
    resp({ status: 200, headers: { "content-type": "text/html" }, body: "<html>app</html>" }),
    resp({
      status: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ datas: { jxlcx: { rows: BUILDING_ROWS } } }),
    }),
    resp({
      status: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ datas: { rqzhzcjc: { ZC: 5, XQJ: 1 } } }),
    }),
    resp({
      status: 200,
      headers: { "content-type": "application/json", "set-cookie": "JSESSIONID=ROTATED" },
      setCookie: ["JSESSIONID=ROTATED; Path=/; Secure"],
      body: JSON.stringify({ datas: { cxjsqk: { rows: CLASSROOM_ROWS } } }),
    }),
  ]);

  const { data } = await runFetchAdapter(
    {
      source,
      capability: "classroom.available",
      params: {
        date: "2026-03-16",
        term: "2025-2026-2",
        buildingId: "BLDG-A",
        sectionStart: 1,
        sectionEnd: 4,
      },
      nowMs: 1_700_000_000_000,
    },
    {
      trust: TrustedAdapterContext.devSideload(),
      view: ehallView(),
      resolver: new FakeResolver({ "ehall-session": { via: "cookie", value: "JSESSIONID=INITIAL" } }),
      transport,
    },
  );

  assert.equal(transport.seen.length, 5, "应请求 appShow、入口、jxlcx、rqzhzcjc、cxjsqk");
  assert.match(transport.seen[2]!.url, /jxlcx\.do/);
  assert.match(transport.seen[3]!.url, /rqzhzcjc\.do/);
  assert.match(transport.seen[4]!.url, /cxjsqk\.do/);
  assert.equal(transport.seen[4]!.headers.Cookie, "JSESSIONID=INITIAL");
  assert.match(transport.seen[4]!.body || "", /JXLDM/, "查询应带教学楼");
  assert.match(transport.seen[4]!.body || "", /XNXQDM=2025-2026-2/);
  assert.equal(transport.seen[4]!.headers["Set-Cookie"], undefined);

  const validate = compileSchema(`${repoRoot}contract/schema/classroom.available.schema.json`);
  assert.ok(validate(data), `available 产出未通过 schema：${JSON.stringify(validate.errors)}`);

  assert.equal(data.date, "2026-03-16");
  assert.equal(data.term, "2025-2026-2");
  assert.equal(data.week, 5);
  assert.equal(data.weekday, 1);
  assert.equal(data.sectionStart, 1);
  assert.equal(data.sectionEnd, 4);
  assert.equal(data.items.length, 2);

  const free = data.items.find((i: { room: string }) => i.room === "A101");
  assert.ok(free);
  assert.equal(free.status, "available");
  assert.equal(free.occupied, false);
  assert.equal(free.sections.length, 11);
  assert.equal(free.sections[4].occupied, true);

  const partial = data.items.find((i: { room: string }) => i.room === "A102");
  assert.ok(partial);
  assert.equal(partial.status, "partial");
  assert.equal(partial.occupied, true);

  console.log("school-xidian classroom.available：凭证注入 + sections 归一化 + schema 通过 ✅");
}

async function main(): Promise<void> {
  const adapterDir = adapterDirIfPresent(repoRoot, "school-xidian");
  if (!adapterDir) {
    skipSmoke(
      "缺 elecon-adapters 兄弟仓（CI 未检出）；本 smoke 依赖公开 adapter 源。见 ADR-018 / mirror-adapters。",
    );
    return;
  }
  const source = readText(`${adapterDir}/index.js`);
  await smokeBuildings(source);
  await smokeAvailable(source);
}

runMain(main);
