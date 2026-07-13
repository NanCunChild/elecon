/**
 * 沙箱冒烟测试 —— 证明 parser 管线端到端跑通。
 *
 *   adapter 源码 + 脱敏夹具  →  QuickJS-wasm 沙箱  →  归一化产出
 *                                                   ├─ 逐字段等于 golden
 *                                                   └─ 通过 contract schema（ajv）
 *
 * 这不是正式校验器（那是 tools/src/validator，下一步）。这是让管线先转起来的最小驱动。
 *
 *   运行：cd server && npm run smoke:sandbox
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

import { runAdapter, SandboxError } from "./sandbox.js";
import { resolveRepoRoot, runMain } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const parserDir = `${repoRoot}adapters/_template/parser`;
const schemaPath = `${repoRoot}contract/schema/grades.list.schema.json`;

interface Fixture {
  capability: string;
  params: unknown;
  responses: Record<string, { status: number; headers: Record<string, string>; body: string }>;
  expected: unknown;
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

async function testGoldenAndSchema(): Promise<void> {
  const source = readFileSync(`${parserDir}/index.js`, "utf8");
  const fixture = readJson<Fixture>(`${parserDir}/fixtures/grades.list.json`);

  const logs: string[] = [];
  const { data } = await runAdapter({
    source,
    capability: fixture.capability,
    params: fixture.params,
    responses: fixture.responses,
    nowMs: 1_700_000_000_000, // 固定，保证确定性（golden 双跑前提）
    onLog: (level, message) => logs.push(`${level}: ${message}`),
  });

  // (a) 逐字段等于 golden
  assert.deepEqual(data, fixture.expected, "产出与 golden 不一致");
  console.log("  ✓ golden 一致");

  // (b) 通过 contract schema（这一步证明管线产出的是合法契约数据）
  const ajv = new Ajv2020({ allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile(readJson(schemaPath));
  const ok = validate(data);
  assert.ok(ok, `产出未通过 grades.list schema：${JSON.stringify(validate.errors)}`);
  console.log("  ✓ 通过 contract schema（ajv）");
}

/** 引擎地板漂移哨兵（服务端半边）。详见 ADR-008 §3。 */
async function testEngineFloorCanary(): Promise<void> {
  const canaryDir = `${repoRoot}adapters/_canary/parser`;
  const source = readFileSync(`${canaryDir}/index.js`, "utf8");
  const fixture = readJson<Fixture>(`${canaryDir}/fixtures/engine_floor.json`);

  const { data } = await runAdapter({
    source,
    capability: fixture.capability,
    params: fixture.params,
    responses: fixture.responses,
    nowMs: 1_700_000_000_000,
  });

  // 非领域 capability：只比 golden，不走 contract schema（它不在 capability registry 内）。
  assert.deepEqual(data, fixture.expected, "engine-floor canary 产出与 golden 不一致");
  console.log("  ✓ engine-floor canary：地板内建产出与 golden 一致");
}

async function testCapabilityMissing(): Promise<void> {
  const source = readFileSync(`${parserDir}/index.js`, "utf8");
  await assert.rejects(
    runAdapter({ source, capability: "schedule.week", params: {}, responses: {} }),
    (err: unknown) => err instanceof SandboxError && err.reason === "capability_missing",
    "未声明的 capability 应抛 capability_missing",
  );
  console.log("  ✓ 缺失 capability 被拒（capability_missing）");
}

async function testTimeoutBites(): Promise<void> {
  // parser 同步死循环；interrupt handler 应在 deadline 后中断
  const source = "export const capabilities = { spin: () => { while (true) {} } };";
  await assert.rejects(
    runAdapter(
      { source, capability: "spin", params: {}, responses: {} },
      { timeoutMs: 200, memoryBytes: 64 * 1024 * 1024 },
    ),
    (err: unknown) => err instanceof SandboxError && err.reason === "timeout",
    "死循环应被超时中断（timeout）",
  );
  console.log("  ✓ 超时限制生效（timeout）");
}

async function testMemoryBites(): Promise<void> {
  // 持续分配触碰 wasm 内存上限；必须归为 memory 而非 timeout/adapter_threw。
  // 错误归类靠消息文案匹配（sandbox-qjs-util unwrap，最佳努力）——本例是哨兵：
  // 引擎升级改 OOM 文案会让归类静默降级为 adapter_threw，此处即变红（审阅 P1-3）。
  // timeoutMs 给宽，确保先撞内存墙而非 deadline。
  const source =
    "export const capabilities = { hog: () => { const a = []; for (;;) a.push(new Array(65536).fill(1)); } };";
  await assert.rejects(
    runAdapter(
      { source, capability: "hog", params: {}, responses: {} },
      { timeoutMs: 30_000, memoryBytes: 8 * 1024 * 1024 },
    ),
    (err: unknown) => err instanceof SandboxError && err.reason === "memory",
    "内存越界应归类为 memory（错误文案漂移哨兵）",
  );
  console.log("  ✓ 内存上限生效（memory）");
}

async function testXidianNoticeList(): Promise<void> {
  const xidianDir = `${repoRoot}adapters/school-xidian`;
  const source = readFileSync(`${xidianDir}/index.js`, "utf8");
  const fixture = readJson<Fixture>(`${xidianDir}/fixtures/notice.list.json`);
  const noticeSchema = readJson(`${repoRoot}contract/schema/notice.list.schema.json`);

  const { data } = await runAdapter({
    source,
    capability: fixture.capability,
    params: fixture.params,
    responses: fixture.responses,
    nowMs: 1_700_000_000_000,
  });

  assert.deepEqual(data, fixture.expected, "XIDIAN notice.list 产出与 golden 不一致");
  console.log("  ✓ XIDIAN notice.list golden 一致");

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(noticeSchema as object);
  const ok = validate(data);
  assert.ok(ok, `XIDIAN notice.list 未通过 schema：${JSON.stringify(validate.errors)}`);
  console.log("  ✓ XIDIAN notice.list 通过 contract schema");
}

async function main(): Promise<void> {
  console.log("sandbox smoke:");
  await testGoldenAndSchema();
  await testEngineFloorCanary();
  await testXidianNoticeList();
  await testCapabilityMissing();
  await testTimeoutBites();
  await testMemoryBites();
  console.log("全部通过。parser 管线端到端跑通。");
}

runMain(main);
