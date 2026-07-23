/**
 * school-xidian schedule.week 凭据注入 smoke。
 *
 * 使用公开仓 adapter + fake transport，不访问 IDS/校园网、不包含真实凭证。
 * 覆盖：E-Hall 请求收到 Broker 注入的 ehall-session cookie、Set-Cookie 不回交 adapter、
 * 课表输出通过 contract schema；SKZC 连续段 / 单周 / 多段周次过滤。
 *
 * 运行：cd server && npm run smoke:xidian-schedule
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
import { runImperativeAdapter } from "./sandbox.js";
import { TrustedAdapterContext } from "./trusted-context.js";

const repoRoot = resolveRepoRoot(import.meta.url);

const SCHEDULE_ROWS = [
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
  {
    KCM: "单周课程",
    KCH: "COURSE-ODD",
    SKZC: "1-16周(单)",
    SKXQ: "3",
    KSJC: "5",
    JSJC: "6",
  },
  {
    KCM: "多段课程",
    KCH: "COURSE-MULTI",
    SKZC: "1-4,8-10周",
    SKXQ: "4",
    KSJC: "1",
    JSJC: "2",
  },
];

function scheduleBody(): string {
  return JSON.stringify({
    datas: {
      xskcb: {
        extParams: { code: 1 },
        rows: SCHEDULE_ROWS,
      },
    },
  });
}

function makeTransport(): FakeTransport {
  return new FakeTransport([
    resp({ status: 302, location: "https://ehall.xidian.edu.cn/new/index.html", body: "" }),
    resp({ status: 200, headers: { "content-type": "text/html" }, body: "<html>app</html>" }),
    resp({
      status: 200,
      headers: { "content-type": "application/json", "set-cookie": "JSESSIONID=ROTATED" },
      setCookie: ["JSESSIONID=ROTATED; Path=/; Secure"],
      body: scheduleBody(),
    }),
  ]);
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
  const view: BrokerManifestView = {
    allow: ["https://ehall.xidian.edu.cn/*"],
    credentials: { "ehall-session": { scope: ["https://ehall.xidian.edu.cn/*"], type: "cookie" } },
  };

  const schema = JSON.parse(readFileSync(`${repoRoot}contract/schema/schedule.week.schema.json`, "utf8"));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  async function runWeek(week: number) {
    const transport = makeTransport();
    const { data } = await runImperativeAdapter(
      {
        source,
        capability: "schedule.week",
        params: { term: "2025-2026-2", week },
        nowMs: 1_700_000_000_000,
      },
      {
        trust: TrustedAdapterContext.devSideload(),
        view,
        resolver: new FakeResolver({ "ehall-session": { via: "cookie", value: "JSESSIONID=INITIAL" } }),
        transport,
      },
    );
    assert.ok(validate(data), `week=${week} schema：${JSON.stringify(validate.errors)}`);
    assert.equal(transport.seen.length, 3, "应请求 appShow、应用入口和课表接口");
    assert.equal(transport.seen[2]!.headers.Cookie, "JSESSIONID=INITIAL", "课表请求应注入 E-Hall cookie");
    assert.equal(transport.seen[2]!.headers["Set-Cookie"], undefined, "adapter 不应控制 Set-Cookie");
    return data as {
      term: string;
      week: number;
      days: {
        dayOfWeek: number;
        slots: {
          start: string;
          end: string;
          courseName: string;
          courseId: string;
          teacher: string;
          location: string;
          weeks: number[];
        }[];
      }[];
    };
  }

  const week3 = await runWeek(3);
  assert.deepEqual(week3, {
    term: "2025-2026-2",
    week: 3,
    days: [
      {
        dayOfWeek: 1,
        slots: [
          {
            start: "1",
            end: "2",
            courseName: "示例课程",
            courseId: "COURSE-EXAMPLE",
            teacher: "示例教师",
            location: "示例教学楼",
            weeks: [1, 2, 3, 4],
          },
        ],
      },
      {
        dayOfWeek: 3,
        slots: [
          {
            start: "5",
            end: "6",
            courseName: "单周课程",
            courseId: "COURSE-ODD",
            teacher: "",
            location: "",
            weeks: [1, 3, 5, 7, 9, 11, 13, 15],
          },
        ],
      },
      {
        dayOfWeek: 4,
        slots: [
          {
            start: "1",
            end: "2",
            courseName: "多段课程",
            courseId: "COURSE-MULTI",
            teacher: "",
            location: "",
            weeks: [1, 2, 3, 4, 8, 9, 10],
          },
        ],
      },
    ],
  });

  const week4 = await runWeek(4);
  const names4 = week4.days.flatMap((d) => d.slots.map((s) => s.courseName)).sort();
  assert.deepEqual(names4, ["多段课程", "示例课程"], "第 4 周应命中连续段+多段，不命中单周课");

  const week9 = await runWeek(9);
  const names9 = week9.days.flatMap((d) => d.slots.map((s) => s.courseName)).sort();
  assert.deepEqual(names9, ["单周课程", "多段课程"], "第 9 周应命中单周+多段第二段");

  console.log("school-xidian schedule.week：凭证注入 + SKZC 周次 + schema 通过 ✅");
}

runMain(main);
