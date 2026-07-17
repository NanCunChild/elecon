/**
 * school-xidian grades.list 凭据注入 smoke。
 * 使用公开仓 adapter + fake transport，不访问真实 IDS/校园网。
 * 运行：cd server && npm run smoke:xidian-grades
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

async function main(): Promise<void> {
  const adapterDir = adapterDirIfPresent(repoRoot, "school-xidian");
  if (!adapterDir) {
    skipSmoke(
      "缺 elecon-adapters 兄弟仓（CI 未检出）；本 smoke 依赖公开 adapter 源。见 ADR-018 / mirror-adapters。",
    );
    return;
  }
  const source = readText(`${adapterDir}/index.js`);
  const transport = new FakeTransport([
    resp({ status: 302, location: "https://ehall.xidian.edu.cn/new/cjcx.html", body: "" }),
    resp({ status: 200, headers: { "content-type": "text/html" }, body: "<html>app</html>" }),
    resp({
      status: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        datas: {
          xscjcx: {
            extParams: { code: 1 },
            rows: [
              {
                XSKCM: "示例课程",
                JXBID: "CLASS-EXAMPLE",
                XNXQDM: "2025-2026-2",
                XF: "3",
                ZCJ: "92",
                XGXKLBDM_DISPLAY: "必修",
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
    { source, capability: "grades.list", params: { term: "2025-2026-2" }, nowMs: 1_700_000_000_000 },
    {
      trust: TrustedAdapterContext.devSideload(),
      view,
      resolver: new FakeResolver({ "ehall-session": { via: "cookie", value: "JSESSIONID=INITIAL" } }),
      transport,
    },
  );

  assert.equal(transport.seen.length, 3, "应请求 appShow、应用入口和成绩接口");
  assert.equal(transport.seen[2]!.headers.Cookie, "JSESSIONID=INITIAL", "成绩请求应注入 E-Hall cookie");
  assert.match(transport.seen[2]!.body || "", /XNXQDM|querySetting/, "成绩请求应携带查询参数");
  assert.equal(transport.seen[2]!.headers["Set-Cookie"], undefined, "adapter 不应控制 Set-Cookie");

  const schema = JSON.parse(readFileSync(`${repoRoot}contract/schema/grades.list.schema.json`, "utf8"));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.ok(validate(data), `成绩产出未通过 schema：${JSON.stringify(validate.errors)}`);
  assert.deepEqual(data, {
    term: "2025-2026-2",
    items: [
      {
        courseId: "CLASS-EXAMPLE",
        courseName: "示例课程",
        credit: 3,
        score: { kind: "numeric", value: 92, max: 100 },
        category: "required",
        status: "final",
      },
    ],
  });
  console.log("school-xidian grades.list：凭证注入 + 响应脱敏 + schema 通过 ✅");
}

runMain(main);
