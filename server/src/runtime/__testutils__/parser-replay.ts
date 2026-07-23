/**
 * 通用 declarative fixture 回放器（ADR-022）。
 *
 * fixture -> QuickJS declarative handler -> expected golden -> contract schema。
 * 只接受仓库内脱敏 fixture，禁止测试路径访问真实学校接口。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { runDeclarativeAdapter } from "../sandbox.js";
import { resolveRepoRoot } from "./smoke-utils.js";

export interface ParserFixtureResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

export interface ParserFixture {
  capability: string;
  params?: unknown;
  responses: Record<string, ParserFixtureResponse>;
  expected: unknown;
}

interface AdapterManifest {
  capabilities: Array<{ id: string; emits: { schema: string } }>;
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

export async function replayParserFixture(
  metaUrl: string,
  adapterDir: string,
  fixtureName = "fixtures/default.json",
): Promise<unknown> {
  const repoRoot = resolveRepoRoot(metaUrl);
  const fixture = readJson<ParserFixture>(join(adapterDir, fixtureName));
  const manifest = readJson<AdapterManifest>(join(adapterDir, "manifest.json"));
  const capability = manifest.capabilities.find((item) => item.id === fixture.capability);

  assert.ok(capability, `fixture capability 未在 manifest 中声明：${fixture.capability}`);

  const source = readFileSync(join(adapterDir, "index.js"), "utf8");
  const { data } = await runDeclarativeAdapter({
    source,
    capability: fixture.capability,
    params: fixture.params ?? {},
    responses: fixture.responses,
    nowMs: 1_700_000_000_000,
  });

  assert.deepStrictEqual(data, fixture.expected, `${fixtureName} 产出与 expected 不一致`);

  const schema = readJson<object>(
    join(repoRoot, "contract/schema", `${capability.emits.schema.replace("elecon.", "")}.schema.json`),
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.ok(
    validate(data),
    `${fixtureName} 产出未通过 ${capability.emits.schema}：${JSON.stringify(validate.errors)}`,
  );

  return data;
}
