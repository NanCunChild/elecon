/**
 * school-fudan notice.list fetch smoke。
 * 使用公开仓脱敏 fixture + fake transport，不访问复旦站点。
 * 运行：cd server && npm run smoke:fudan-notice
 */
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import {
  adapterDirIfPresent,
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
  const adapterDir = adapterDirIfPresent(repoRoot, "school-fudan");
  if (!adapterDir) {
    skipSmoke(
      "缺 elecon-adapters 兄弟仓（CI 未检出）；本 smoke 依赖公开 adapter 源。见 ADR-018 / mirror-adapters。",
    );
    return;
  }
  const source = readText(`${adapterDir}/index.js`);
  const fixture = JSON.parse(readText(`${adapterDir}/fixtures/notice.list.json`));
  const transport = new FakeTransport([
    resp({ status: 200, headers: { "content-type": "text/html" }, body: fixture.responses.page.body }),
  ]);
  const view: BrokerManifestView = { allow: ["https://jwc.fudan.edu.cn/*"] };
  const { data } = await runFetchAdapter(
    { source, capability: "notice.list", params: fixture.params, nowMs: 1_700_000_000_000 },
    {
      trust: TrustedAdapterContext.devSideload(),
      view,
      resolver: {
        async get() {
          return null;
        },
      },
      transport,
    },
  );

  assert.equal(transport.seen[0]!.url, "https://jwc.fudan.edu.cn/9397/list.htm");
  const schema = JSON.parse(readFileSync(`${repoRoot}contract/schema/notice.list.schema.json`, "utf8"));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.ok(validate(data), `FDU notice.list 未通过 schema：${JSON.stringify(validate.errors)}`);
  assert.deepEqual(data, fixture.expected);
  console.log("school-fudan notice.list：fake fetch + schema + golden 通过 ✅");
}

runMain(main);
