/**
 * school-xidian schedule.week 凭据注入 smoke。
 *
 * 使用公开仓 adapter + fake transport，不访问 IDS/校园网、不包含真实凭证。
 * 覆盖：E-Hall 请求收到 Broker 注入的 ehall-session cookie、Set-Cookie 不回交 adapter、
 * 课表输出通过 contract schema。
 *
 * 运行：cd server && npm run smoke:xidian-schedule
 */
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import {
  FakeResolver,
  FakeTransport,
  readText,
  resp,
  resolveRepoRoot,
  runMain,
} from "./__testutils__/smoke-utils.js";
import type { BrokerManifestView } from "./broker/inject-policy.js";
import { runFetchAdapter } from "./sandbox.js";
import { TrustedAdapterContext } from "./trusted-context.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const publicRoot = process.env.ELECON_ADAPTERS_REPO ?? `${repoRoot}../elecon-adapters/`;
const adapterDir = `${publicRoot.replace(/\/$/, "")}/adapters/school-xidian`;

async function main(): Promise<void> {
  const source = readText(`${adapterDir}/index.js`);
  const transport = new FakeTransport([
    resp({ status: 302, location: "https://ehall.xidian.edu.cn/new/index.html", body: "" }),
    resp({ status: 200, headers: { "content-type": "text/html" }, body: "<html>app</html>" }),
    resp({
      status: 200,
      headers: { "content-type": "application/json", "set-cookie": "JSESSIONID=ROTATED" },
      setCookie: ["JSESSIONID=ROTATED; Path=/; Secure"],
      body: JSON.stringify({
        datas: {
          xskcb: {
            extParams: { code: 1 },
            rows: [
              {
                KCM: "示例课程",
                KCH: "COURSE-EXAMPLE",
                SKJS: "示例教师",
                JASMC: "示例教学楼",
                SKZC: "1-4周",
                SKXQ: "1",
                KSJC: "1",
                JSJC: "2",
              },
              {
                KCM: "其他周课程",
                SKZC: "5-8周",
                SKXQ: "2",
                KSJC: "3",
                JSJC: "4",
              },
            ],
          },
        },
      }),
    }),
  ]);
  const view: BrokerManifestView = {
    allow: ["https://ehall.xidian.edu.cn/*"],
    credentials: { "ehall-session": { scope: ["https://ehall.xidian.edu.cn/*"], type: "cookie" } },
  };

  const { data } = await runFetchAdapter(
    { source, capability: "schedule.week", params: { term: "2025-2026-2", week: 3 }, nowMs: 1_700_000_000_000 },
    {
      trust: TrustedAdapterContext.devSideload(),
      view,
      resolver: new FakeResolver({ "ehall-session": { via: "cookie", value: "JSESSIONID=INITIAL" } }),
      transport,
    },
  );

  assert.equal(transport.seen.length, 3, "应请求 appShow、应用入口和课表接口");
  assert.equal(transport.seen[2]!.headers.Cookie, "JSESSIONID=INITIAL", "课表请求应注入 E-Hall cookie");
  assert.equal(transport.seen[2]!.headers["Set-Cookie"], undefined, "adapter 不应控制 Set-Cookie");

  const schema = JSON.parse(readFileSync(`${repoRoot}contract/schema/schedule.week.schema.json`, "utf8"));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.ok(validate(data), `课表产出未通过 schema：${JSON.stringify(validate.errors)}`);
  assert.deepEqual(data, {
    term: "2025-2026-2",
    week: 3,
    days: [{
      dayOfWeek: 1,
      slots: [{
        start: "1",
        end: "2",
        courseName: "示例课程",
        courseId: "COURSE-EXAMPLE",
        teacher: "示例教师",
        location: "示例教学楼",
        weeks: [1, 2, 3, 4],
      }],
    }],
  });
  console.log("school-xidian schedule.week：凭证注入 + 响应脱敏 + schema 通过 ✅");
}

runMain(main);
