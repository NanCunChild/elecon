/**
 * school-xidian card.* query credential smoke（ADR-020；fake transport only）。
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
const credential = "OPENID_FAKE_CREDENTIAL";
const accountHtml = "<html><body><p>校园卡号：CARD-EXAMPLE-0001</p><p>账户余额：￥123.45</p></body></html>";

function cardView(): BrokerManifestView {
  return {
    allow: ["https://v8scan.xidian.edu.cn/*"],
    credentials: {
      "card-session": {
        scope: ["https://v8scan.xidian.edu.cn/*"],
        type: "query",
        queryParam: "openid",
      },
    },
  };
}

function validateSchema(name: string, data: unknown): void {
  const schema = JSON.parse(readFileSync(`${repoRoot}contract/schema/${name}.schema.json`, "utf8"));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.ok(validate(data), `${name} 产出未通过 schema：${JSON.stringify(validate.errors)}`);
}

async function runCapability(
  source: string,
  capability: "card.balance" | "card.transactions",
  responses: ReturnType<typeof resp>[],
) {
  const transport = new FakeTransport(responses);
  const result = await runImperativeAdapter(
    {
      source,
      capability,
      params: capability === "card.transactions" ? { page: 1, size: 20 } : {},
      nowMs: 1_700_000_000_000,
    },
    {
      trust: TrustedAdapterContext.devSideload(),
      view: cardView(),
      resolver: new FakeResolver({ "card-session": { via: "query", value: credential } }),
      transport,
    },
  );
  for (const request of transport.seen) {
    assert.equal(new URL(request.url).searchParams.get("openid"), credential);
    assert.doesNotMatch(request.body ?? "", /OPENID_FAKE_CREDENTIAL/);
  }
  assert.doesNotMatch(JSON.stringify(result.data), /OPENID_FAKE_CREDENTIAL/);
  return { data: result.data, transport };
}

async function main(): Promise<void> {
  const adapterDir = adapterDirIfPresent(repoRoot, "school-xidian");
  if (!adapterDir) {
    skipSmoke("缺 elecon-adapters 兄弟仓（CI 未检出），跳过 XIDIAN card smoke。");
    return;
  }
  const source = readText(`${adapterDir}/index.js`);

  const balance = await runCapability(source, "card.balance", [
    resp({ status: 200, headers: { "content-type": "text/html" }, body: accountHtml }),
  ]);
  validateSchema("card.balance", balance.data);
  assert.equal((balance.data as { balance: { amountMinor: number } }).balance.amountMinor, 12345);

  const transactions = await runCapability(source, "card.transactions", [
    resp({ status: 200, headers: { "content-type": "text/html" }, body: accountHtml }),
    resp({
      status: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        success: true,
        resultData: {
          total: 1,
          rows: [
            {
              id: "TX-EXAMPLE-0001",
              txdate: "2026-01-01 12:00:00",
              txamt: "-12.50",
              txname: "消费",
              mername: "示例商户",
            },
          ],
        },
      }),
    }),
  ]);
  validateSchema("card.transactions", transactions.data);
  assert.match(transactions.transport.seen[1]!.body ?? "", /pageNo=1&pageSize=20/);
  const item = (transactions.data as { items: Array<{ amountMinor: number; direction: string }> }).items[0]!;
  assert.deepEqual(item, {
    time: "2026-01-01T04:00:00.000Z",
    amountMinor: 1250,
    currency: "CNY",
    direction: "debit",
    merchant: "示例商户",
    transactionId: "TX-EXAMPLE-0001",
  });
  console.log("school-xidian card.*：query credential + schema 通过");
}

runMain(main);
