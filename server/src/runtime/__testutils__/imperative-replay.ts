/** 通用 imperative fixture 回放器（ADR-022）：固定响应队列，禁止测试访问真实学校接口。 */

import { strict as assert } from "node:assert";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import type { BrokerManifestView } from "../broker/inject-policy.js";
import { parseMaskerPolicy } from "../broker/masker-policy.js";
import { CredentialStore } from "../credential/store.js";
import { runImperativeAdapter } from "../sandbox.js";
import { TrustedAdapterContext } from "../trusted-context.js";
import { FakeTransport, noResolver, resolveRepoRoot } from "./smoke-utils.js";

interface Manifest {
  schoolId?: string;
  network: { allow: string[] };
  capabilities: Array<{ id: string; emits: { schema: string } }>;
}

interface ResponseFixture {
  status: number;
  headers?: Record<string, string>;
  body?: string;
  bodyFile?: string;
  bodyJsonFile?: string;
  bodyJsonPath?: string;
  setCookieFile?: string;
}

interface ImperativeFixture {
  capability: string;
  params?: unknown;
  responses: ResponseFixture[];
  expected: unknown;
  assertions?: {
    requestCount?: number;
    methods?: string[];
    cookieIncludes?: Array<{ request: number; value: string }>;
    itemCount?: number;
    itemSource?: string;
    itemCategory?: string;
  };
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function jsonPath(value: unknown, path: string | undefined): unknown {
  if (!path) return value;
  return path.split(".").reduce((current: unknown, key) => {
    if (typeof current !== "object" || current === null) return undefined;
    return (current as Record<string, unknown>)[key];
  }, value);
}

export async function replayImperativeFixture(
  metaUrl: string,
  adapterDir: string,
  fixtureName: string,
): Promise<unknown> {
  const repoRoot = resolveRepoRoot(metaUrl);
  const fixture = readJson<ImperativeFixture>(join(adapterDir, fixtureName));
  const manifest = readJson<Manifest>(join(adapterDir, "manifest.json"));
  const capability = manifest.capabilities.find((item) => item.id === fixture.capability);
  assert.ok(capability, `fixture capability 未在 manifest 中声明：${fixture.capability}`);

  const responses = fixture.responses.map((response) => {
    let body = response.body ?? "";
    if (response.bodyFile) body = readFileSync(join(adapterDir, response.bodyFile), "utf8");
    if (response.bodyJsonFile) {
      const json = readJson<unknown>(join(adapterDir, response.bodyJsonFile));
      body = JSON.stringify(jsonPath(json, response.bodyJsonPath));
    }
    const setCookie = response.setCookieFile
      ? [
          readJson<{ headers: Record<string, string> }>(join(adapterDir, response.setCookieFile)).headers[
            "Set-Cookie"
          ]!,
        ]
      : [];
    return {
      status: response.status,
      headers: response.headers ?? {},
      setCookie,
      location: null,
      body,
    };
  });

  const transport = new FakeTransport(responses);
  const view: BrokerManifestView = { allow: manifest.network.allow };
  const source = readFileSync(join(adapterDir, "index.js"), "utf8");
  // 与生产装配同形：adapter 根若带 masker.json（/3 起 official 必带），按 §2.7.1 严格解析后接入 firewall；
  // 收割落点用独立 store（replay 只验产出，不验落库）。缺文件时 devSideload 走无策略透明交付。
  const maskerPath = join(adapterDir, "masker.json");
  const masker = existsSync(maskerPath)
    ? {
        policy: parseMaskerPolicy(readFileSync(maskerPath, "utf8")),
        sink: new CredentialStore(undefined, () => 1_700_000_000_000),
        ctx: { schoolId: manifest.schoolId ?? "", now: () => 1_700_000_000_000 },
      }
    : undefined;
  const { data } = await runImperativeAdapter(
    { source, capability: fixture.capability, params: fixture.params ?? {}, nowMs: 1_700_000_000_000 },
    {
      trust: TrustedAdapterContext.devSideload(),
      view,
      resolver: noResolver,
      transport,
      ...(masker === undefined ? {} : { masker }),
    },
  );

  assert.deepStrictEqual(data, fixture.expected, `${fixtureName} 产出与 expected 不一致`);
  assert.equal(transport.seen.length, fixture.responses.length, `${fixtureName} 未恰好消费完整响应输入链`);

  const assertions = fixture.assertions ?? {};
  if (assertions.requestCount !== undefined) assert.equal(transport.seen.length, assertions.requestCount);
  for (const [index, method] of (assertions.methods ?? []).entries()) {
    assert.equal(transport.seen[index]?.method, method, `第 ${index + 1} 次请求 method 不符`);
  }
  for (const cookie of assertions.cookieIncludes ?? []) {
    assert.ok(
      transport.seen[cookie.request]?.headers.Cookie?.includes(cookie.value),
      `第 ${cookie.request + 1} 次请求缺少 cookie：${cookie.value}`,
    );
  }

  const result = data as { items?: Array<{ source?: string; category?: string }> };
  if (assertions.itemCount !== undefined) assert.equal(result.items?.length, assertions.itemCount);
  if (assertions.itemSource !== undefined)
    assert.ok(result.items?.every((item) => item.source === assertions.itemSource));
  if (assertions.itemCategory !== undefined)
    assert.ok(result.items?.every((item) => item.category === assertions.itemCategory));

  const schemaName = capability.emits.schema.replace("elecon.", "");
  const schema = readJson<object>(join(repoRoot, "contract/schema", `${schemaName}.schema.json`));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.ok(
    validate(data),
    `imperative fixture 产出未通过 ${capability.emits.schema}：${JSON.stringify(validate.errors)}`,
  );
  return data;
}
