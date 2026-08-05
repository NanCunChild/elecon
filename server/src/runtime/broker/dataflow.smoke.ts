/**
 * 声明式数据流执行器 golden 冒烟（ADR-023 §2.3/§2.4）。
 *
 *   contract/golden/broker/dataflow.json  →  broker/dataflow.ts 纯函数  →  逐例等于 expected
 *
 * 同一份 golden 由客户端（Dart，§5）照样跑（两端双跑，ADR-001 §8）。覆盖 5 段：
 * ops（逐 op 语义 + 跨端陷阱）/ extract（抽取 + fail-closed）/ inject / topo。
 * （注入值回显剥离 strip/echoTargets 已于 2026-08-05 退役，ADR-023 §2.5 → Masker redact。）
 *
 *   运行：cd server && npm run smoke:dataflow
 *
 * 🔒 本测试覆盖红线 #1 数据流路径；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { resolveRepoRoot } from "../__testutils__/smoke-utils.js";
import {
  applyInjections,
  type BindDecl,
  type ComputeDecl,
  DataflowError,
  evalComputeGraph,
  evalOp,
  extractHandle,
  type HandleValue,
  type InjectDecl,
  planRequestOrder,
  type RawResponse,
  type RequestDecl,
  resolveInjections,
} from "./dataflow.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const golden = JSON.parse(
  readFileSync(`${repoRoot}contract/golden/broker/dataflow.json`, "utf8"),
) as GoldenFile;

interface GoldenHandle {
  type: "text" | "bytes";
  text?: string;
  hex?: string;
}
interface GoldenFile {
  nowMs: number;
  ops: Array<{
    name: string;
    op: string;
    args: GoldenHandle[];
    params?: Record<string, unknown>;
    expected?: GoldenHandle;
    error?: string;
  }>;
  extract: Array<{
    name: string;
    bind: BindDecl;
    response: RawResponse;
    expected?: GoldenHandle;
    error?: string;
  }>;
  inject: Array<{
    name: string;
    request: RequestDecl;
    injects: InjectDecl[];
    env: Record<string, GoldenHandle>;
    expected?: { url: string; headers: Record<string, string> };
    error?: string;
  }>;
  pipelines: Array<{
    name: string;
    env: Record<string, GoldenHandle>;
    computes: ComputeDecl[];
    injects: InjectDecl[];
    request: RequestDecl;
    expected: {
      handles: Record<string, GoldenHandle>;
      url: string;
      headers: Record<string, string>;
    };
  }>;
  topo: Array<{
    name: string;
    requests: RequestDecl[];
    binds: BindDecl[];
    computes: ComputeDecl[];
    injects: InjectDecl[];
    expected: string[][];
  }>;
}

/** golden 句柄表示 → 运行期 HandleValue。 */
function toHandle(g: GoldenHandle): HandleValue {
  if (g.type === "bytes") return { type: "bytes", bytes: Uint8Array.from(Buffer.from(g.hex ?? "", "hex")) };
  return { type: "text", text: g.text ?? "" };
}

/** 运行期 HandleValue → golden 可比对形（bytes 转 hex）。 */
function fromHandle(h: HandleValue): GoldenHandle {
  return h.type === "bytes"
    ? { type: "bytes", hex: Buffer.from(h.bytes).toString("hex") }
    : { type: "text", text: h.text };
}

/** 断言 [fn] 抛出 DataflowError 且 code 匹配。 */
function assertError(fn: () => unknown, code: string, label: string): void {
  try {
    fn();
    assert.fail(`${label}：期望 fail-closed（${code}），但未抛错`);
  } catch (err) {
    assert.ok(err instanceof DataflowError, `${label}：期望 DataflowError，实得 ${err}`);
    assert.equal(err.code, code, `${label}：错误码不符`);
  }
}

let passed = 0;

// ---- ops ----
for (const c of golden.ops) {
  const args = c.args.map(toHandle);
  if (c.error) {
    assertError(() => evalOp(c.op, args, c.params, golden.nowMs), c.error, `op ${c.name}`);
  } else {
    const actual = fromHandle(evalOp(c.op, args, c.params, golden.nowMs));
    assert.deepStrictEqual(actual, c.expected, `op ${c.name}`);
  }
  passed++;
}
console.log(`  ✓ ops: ${golden.ops.length} 例`);

// ---- extract ----
for (const c of golden.extract) {
  if (c.error) {
    assertError(() => extractHandle(c.bind, c.response), c.error, `extract ${c.name}`);
  } else {
    const actual = fromHandle(extractHandle(c.bind, c.response));
    assert.deepStrictEqual(actual, c.expected, `extract ${c.name}`);
  }
  passed++;
}
console.log(`  ✓ extract: ${golden.extract.length} 例`);

// ---- regex 严格线性子集（ADR-023；不得调用原生 RegExp）----
{
  const cases: Array<{ pattern: string; body: string; group?: number; expected: string }> = [
    { pattern: "client_id=([a-z0-9]+)", body: "x client_id=ab12_", group: 1, expected: "ab12" },
    { pattern: "[0-9]{4}", body: "year=2026", expected: "2026" },
    { pattern: "zzz([0-9]+)", body: "--zzz42!", group: 1, expected: "42" },
    { pattern: "id=(\\w+)", body: "id=user_7", group: 1, expected: "user_7" },
    { pattern: "session_key=(\\w+)", body: "session_key=K_9", group: 1, expected: "K_9" },
    { pattern: "client_id:'(\\w+)'", body: "client_id:'abc_1'", group: 1, expected: "abc_1" },
    { pattern: "seed=(\\w+)", body: "seed=a9", group: 1, expected: "a9" },
    { pattern: "seed=(.+)$", body: "prefix seed=a b", group: 1, expected: "a b" },
    { pattern: "token=(\\w+)", body: "token=T0", group: 1, expected: "T0" },
    { pattern: "v=(\\w+)", body: "v=x_1", group: 1, expected: "x_1" },
    { pattern: "^id=(\\w+)$", body: "id=root", group: 1, expected: "root" },
    { pattern: "(.)", body: "😀", group: 1, expected: "😀" },
  ];
  for (const c of cases) {
    const value = extractHandle(
      {
        var: "x",
        from: "A",
        source: "regex",
        extract: { pattern: c.pattern, ...(c.group === undefined ? {} : { group: c.group }) },
      },
      { status: 200, headers: {}, body: c.body },
    );
    assert.deepStrictEqual(fromHandle(value), { type: "text", text: c.expected }, c.pattern);
    passed++;
  }
  assert.deepStrictEqual(
    fromHandle(
      extractHandle(
        { var: "x", from: "A", source: "regex", extract: { pattern: "seed=(.+)$", group: 1 } },
        { status: 200, headers: {}, body: "header\nseed=value\n" },
      ),
    ),
    { type: "text", text: "value" },
    "unanchored end-anchored dot scans only the final line",
  );
  passed++;
  for (const pattern of [
    "(a|aa)+$",
    "a*a*b",
    "(?=a)a",
    "(a)+",
    "a+?",
    "a+b",
    "\\bword",
    "[\\q]",
    "\\s(.+)$",
  ]) {
    assertError(
      () =>
        extractHandle(
          { var: "x", from: "A", source: "regex", extract: { pattern } },
          { status: 200, headers: {}, body: "a".repeat(4096) + "b" },
        ),
      "extract_bad_pattern",
      `regex ${pattern}`,
    );
    passed++;
  }
  assertError(
    () =>
      extractHandle(
        { var: "x", from: "A", source: "regex", extract: { pattern: "(a)", group: 2 } },
        { status: 200, headers: {}, body: "a" },
      ),
    "extract_not_found",
    "regex group 越界保持既有行为",
  );
  passed++;
  console.log("  ✓ regex: 现有模式、捕获、锚点、安全拒绝与 group 越界");
}

// ---- inject ----
for (const c of golden.inject) {
  const env = new Map<string, HandleValue>(Object.entries(c.env).map(([k, v]) => [k, toHandle(v)]));
  if (c.error) {
    assertError(() => resolveInjections(c.injects, env), c.error, `inject ${c.name}`);
  } else {
    const effects = resolveInjections(c.injects, env);
    const actual = applyInjections(c.request, effects);
    assert.deepStrictEqual(actual, c.expected, `inject ${c.name}`);
  }
  passed++;
}
console.log(`  ✓ inject: ${golden.inject.length} 例`);

// ---- pipelines（bytes → text 编码后继续参与声明式 compute / inject）----
for (const c of golden.pipelines) {
  const initial = new Map<string, HandleValue>(
    Object.entries(c.env).map(([name, handle]) => [name, toHandle(handle)]),
  );
  const env = evalComputeGraph(initial, c.computes, golden.nowMs);
  const applied = applyInjections(c.request, resolveInjections(c.injects, env));
  for (const [name, expected] of Object.entries(c.expected.handles)) {
    assert.deepStrictEqual(fromHandle(env.get(name)!), expected, `${c.name} handle ${name}`);
  }
  assert.deepStrictEqual(
    { url: applied.url, headers: applied.headers ?? {} },
    { url: c.expected.url, headers: c.expected.headers },
    c.name,
  );
  passed++;
}
console.log(`  ✓ pipelines: ${golden.pipelines.length} 例`);

// ---- topo ----
for (const c of golden.topo) {
  const actual = planRequestOrder(c.requests, c.binds, c.computes, c.injects);
  assert.deepStrictEqual(actual, c.expected, `topo ${c.name}`);
  passed++;
}
console.log(`  ✓ topo: ${golden.topo.length} 例`);

// ---- 组合：challenge → 抽取 → compute → inject → strip 端到端（非 golden，验证串联）----
{
  const chal: RawResponse = { status: 200, headers: {}, body: "session_key=SECRETKEY0011; client_id=cust42" };
  const binds: BindDecl[] = [
    { var: "key", from: "chal", source: "regex", extract: { pattern: "session_key=(\\w+)", group: 1 } },
    { var: "cid", from: "chal", source: "regex", extract: { pattern: "client_id=(\\w+)", group: 1 } },
  ];
  const bound = new Map<string, HandleValue>();
  for (const b of binds) bound.set(b.var, extractHandle(b, chal));
  const computes: ComputeDecl[] = [
    { var: "mac", op: "hmac-sha256", args: [{ ref: "key" }, { ref: "cid" }] },
    { var: "sig", op: "hex", args: [{ ref: "mac" }], params: { case: "lower" } },
  ];
  const env = evalComputeGraph(bound, computes, golden.nowMs);
  const injects: InjectDecl[] = [{ var: "sig", into: "raw", at: "url", name: "sig" }];
  const effects = resolveInjections(injects, env);
  const raw: RequestDecl = { key: "raw", method: "GET", url: "https://h.edu.cn/api/grades" };
  const applied = applyInjections(raw, effects);
  const sig = env.get("sig")!;
  assert.equal(sig.type, "text");
  assert.ok(applied.url.startsWith("https://h.edu.cn/api/grades?sig="), "sig 应注入 raw.url");
  passed++;
  console.log("  ✓ 端到端串联：抽取→hmac→hex→注入");
}

console.log(`\ndataflow 执行器 smoke: ${passed} 例通过 ✅`);
