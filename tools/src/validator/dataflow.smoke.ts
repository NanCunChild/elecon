/**
 * 声明式数据流校验冒烟测试（ADR-023 · D1–D16）。
 *
 * 针对 checkDataflow / checkRegexSyntax 的纯逻辑断言（不碰文件系统）。**重心是安全负例**：
 * 类型不匹配、字面量密钥、超限额、非法 regex、凭证头注入、成环、信任门（AGENTS.md §1
 * 要求数据流路径配套安全清单 + 负例）。端到端由 `npm run validate` 对真实 fixture 验证。
 *
 *   运行：cd tools && npm run smoke:dataflow
 */

import { strict as assert } from "node:assert";

import {
  checkDataflow,
  checkRegexSyntax,
  type DataflowCapability,
  MAX_COMPUTE_DEPTH,
  MAX_DATAFLOW_NODES,
} from "./dataflow.js";

interface Finding {
  code: string;
  level: string;
}

function codes(findings: Finding[]): string[] {
  return findings.map((f) => f.code);
}

function errorsOf(findings: Finding[]): string[] {
  return findings.filter((f) => f.level === "error").map((f) => f.code);
}

/** 包一个 declarative + sideload 的最小 manifest（DEV 同权，D13 通过）。 */
function wrap(cap: Partial<DataflowCapability>, trustTier = "sideload") {
  return {
    trustTier,
    capabilities: [
      {
        id: "grades.list",
        requestGraph: "declarative" as const,
        requests: [{ key: "A" }, { key: "B" }, { key: "C" }],
        ...cap,
      },
    ],
  };
}

// ============ 正例：合法数据流无 error ============
{
  const findings = checkDataflow(
    wrap({
      bind: [
        { var: "auth_a", from: "A", source: "header", extract: { name: "X-Auth" } },
        { var: "tok_b", from: "B", source: "body", extract: { jsonpath: "$.token" } },
        { var: "cid", from: "A", source: "regex", extract: { pattern: "client_id=(\\w+)", group: 1 } },
      ],
      compute: [
        { var: "joined", op: "concat", args: [{ ref: "auth_a" }, { ref: "tok_b" }, { text: "!" }] },
        { var: "mac", op: "hmac-sha256", args: [{ ref: "auth_a" }, { ref: "joined" }] },
        { var: "sig", op: "hex", args: [{ ref: "mac" }], params: { case: "lower" } },
      ],
      inject: [
        { var: "sig", into: "C", at: "url", name: "sig" },
        { var: "cid", into: "C", at: "header", name: "X-Client-Id" },
      ],
    }),
  );
  assert.equal(
    errorsOf(findings).length,
    0,
    `合法数据流应无 error，实得 ${JSON.stringify(errorsOf(findings))}`,
  );
  console.log("  ✓ 合法 bind/compute/inject 无 error");
}

// ============ D1：非 declarative 声明数据流被拒 ============
{
  const findings = checkDataflow({
    trustTier: "official",
    capabilities: [
      {
        id: "grades.list",
        requestGraph: "imperative",
        bind: [{ var: "x", from: "A", source: "header", extract: { name: "X" } }],
      },
    ],
  });
  assert.ok(errorsOf(findings).includes("D1_dataflow_requires_declarative"), "imperative + 数据流应触发 D1");
  console.log("  ✓ imperative 声明数据流被拒（D1）");
}

// ============ D2：bind.from 指向未声明 request ============
{
  const findings = checkDataflow(
    wrap({ bind: [{ var: "x", from: "ZZZ", source: "header", extract: { name: "X" } }] }),
  );
  assert.ok(errorsOf(findings).includes("D2_bind_unknown_request"), "未知 from 应触发 D2");
  console.log("  ✓ bind.from 指向未声明 request 被拒（D2）");
}

// ============ D3：变量名重复 ============
{
  const findings = checkDataflow(
    wrap({
      bind: [
        { var: "dup", from: "A", source: "header", extract: { name: "X" } },
        { var: "dup", from: "B", source: "header", extract: { name: "Y" } },
      ],
    }),
  );
  assert.ok(errorsOf(findings).includes("D3_duplicate_var"), "重名应触发 D3");
  console.log("  ✓ 变量名重复被拒（D3）");
}

// ============ D4：extract 键集合与 source 不符 ============
{
  // header 却给 jsonpath
  const f1 = checkDataflow(
    wrap({ bind: [{ var: "x", from: "A", source: "header", extract: { jsonpath: "$.x" } }] }),
  );
  assert.ok(errorsOf(f1).includes("D4_extract_shape"), "header+jsonpath 应触发 D4");
  // body 却多给 name
  const f2 = checkDataflow(
    wrap({
      bind: [{ var: "x", from: "A", source: "body", extract: { jsonpath: "$.x", name: "X" } }],
    }),
  );
  assert.ok(errorsOf(f2).includes("D4_extract_shape"), "body 多余 name 应触发 D4");
  console.log("  ✓ extract 键集合与 source 不符被拒（D4）");
}

// ============ D5：regex 语法白名单 ============
{
  // 嵌套量词
  assert.ok(checkRegexSyntax("(a+)+$").reason !== null, "(a+)+ 应被拒（嵌套量词）");
  assert.ok(checkRegexSyntax("(?:ab*)*").reason !== null, "(?:ab*)* 应被拒（嵌套量词）");
  assert.ok(checkRegexSyntax("((a{2})){3}").reason !== null, "((a{2})){3} 应被拒（嵌套量词外传）");
  // lookbehind
  assert.ok(checkRegexSyntax("(?<=x)y").reason !== null, "lookbehind 应被拒");
  // 反向引用
  assert.ok(checkRegexSyntax("(a)\\1").reason !== null, "反向引用应被拒");
  // 命名组
  assert.ok(checkRegexSyntax("(?<n>a)").reason !== null, "命名组应被拒");
  // 合法
  const ok = checkRegexSyntax("client_id=(\\w+)&");
  assert.equal(ok.reason, null, `合法模式不应被拒，实得 ${ok.reason}`);
  assert.equal(ok.groupCount, 1, "捕获组计数应为 1");
  // lookahead 放行
  assert.equal(checkRegexSyntax("foo(?=bar)").reason, null, "lookahead 应放行");
  // group 越界（模式只有 1 组，取 group 2）
  const f = checkDataflow(
    wrap({ bind: [{ var: "x", from: "A", source: "regex", extract: { pattern: "(a)", group: 2 } }] }),
  );
  assert.ok(errorsOf(f).includes("D5_regex_group_out_of_range"), "group 越界应触发 D5");
  // 非法语法在 bind 层报 D5
  const f2 = checkDataflow(
    wrap({ bind: [{ var: "x", from: "A", source: "regex", extract: { pattern: "(a+)+" } }] }),
  );
  assert.ok(errorsOf(f2).includes("D5_regex_syntax_rejected"), "非法 regex 应触发 D5");
  console.log("  ✓ regex 语法白名单（嵌套量词/lookbehind/反向引用/命名组/group 越界）（D5）");
}

// ============ D6：arg 形状（须恰有 ref 或 text 之一）============
{
  const both = checkDataflow(
    wrap({
      bind: [{ var: "a", from: "A", source: "header", extract: { name: "X" } }],
      compute: [{ var: "c", op: "concat", args: [{ ref: "a", text: "x" }, { ref: "a" }] }],
    }),
  );
  assert.ok(errorsOf(both).includes("D6_bad_arg_shape"), "ref+text 兼有应触发 D6");
  const neither = checkDataflow(
    wrap({
      bind: [{ var: "a", from: "A", source: "header", extract: { name: "X" } }],
      compute: [{ var: "c", op: "concat", args: [{}, { ref: "a" }] }],
    }),
  );
  assert.ok(errorsOf(neither).includes("D6_bad_arg_shape"), "空 arg 应触发 D6");
  console.log("  ✓ arg 须恰有 ref 或 text 之一（D6）");
}

// ============ D7：前向引用 / 未定义引用 → 无环保证 ============
{
  // 引用声明序在后的 compute
  const forward = checkDataflow(
    wrap({
      bind: [{ var: "a", from: "A", source: "header", extract: { name: "X" } }],
      compute: [
        { var: "c1", op: "concat", args: [{ ref: "c2" }, { ref: "a" }] },
        { var: "c2", op: "concat", args: [{ ref: "a" }, { ref: "a" }] },
      ],
    }),
  );
  assert.ok(errorsOf(forward).includes("D7_undefined_or_forward_ref"), "前向引用应触发 D7");
  // 未定义
  const undef = checkDataflow(
    wrap({ compute: [{ var: "c", op: "concat", args: [{ ref: "nope" }, { text: "x" }] }] }),
  );
  assert.ok(errorsOf(undef).includes("D7_undefined_or_forward_ref"), "未定义引用应触发 D7");
  console.log("  ✓ 前向/未定义引用被拒（D7 → DAG 无环）");
}

// ============ D8：op 元数 / params 键集合 / 取值域 ============
{
  // 未知 op
  const unknownOp = checkDataflow(wrap({ compute: [{ var: "c", op: "sha1", args: [{ text: "x" }] }] }));
  assert.ok(errorsOf(unknownOp).includes("D8_unknown_op"), "未知 op 应触发 D8");
  // 元数不符（concat 至少 2）
  const arity = checkDataflow(wrap({ compute: [{ var: "c", op: "concat", args: [{ text: "x" }] }] }));
  assert.ok(errorsOf(arity).includes("D8_op_arity_mismatch"), "concat 单参应触发 D8 元数");
  // 缺 params（substring 缺 start/length）
  const missP = checkDataflow(
    wrap({
      bind: [{ var: "a", from: "A", source: "header", extract: { name: "X" } }],
      compute: [{ var: "c", op: "substring", args: [{ ref: "a" }] }],
    }),
  );
  assert.ok(errorsOf(missP).includes("D8_missing_param"), "substring 缺 params 应触发 D8");
  // 多余 params
  const extraP = checkDataflow(
    wrap({ compute: [{ var: "c", op: "now", args: [], params: { format: "iso8601", tz: "utc" } }] }),
  );
  assert.ok(errorsOf(extraP).includes("D8_unexpected_param"), "now 多余 params 应触发 D8");
  // 取值域外
  const badEnum = checkDataflow(
    wrap({
      bind: [{ var: "a", from: "A", source: "header", extract: { name: "X" } }],
      compute: [{ var: "c", op: "base64", args: [{ ref: "a" }], params: { variant: "mime" } }],
    }),
  );
  assert.ok(errorsOf(badEnum).includes("D8_param_out_of_range"), "base64 非法 variant 应触发 D8");
  console.log("  ✓ op 元数 / params 键集合 / 取值域（D8）");
}

// ============ D9：静态类型 bytes/text ============
{
  // concat 混接 bytes（hmac 输出）与 text
  const mix = checkDataflow(
    wrap({
      bind: [{ var: "a", from: "A", source: "header", extract: { name: "X" } }],
      compute: [
        { var: "mac", op: "hmac-sha256", args: [{ ref: "a" }, { ref: "a" }] },
        { var: "c", op: "concat", args: [{ ref: "mac" }, { text: "x" }] }, // concat 只接 text
      ],
    }),
  );
  assert.ok(errorsOf(mix).includes("D9_type_mismatch"), "concat 接 bytes 应触发 D9");
  // inject bytes（未经 hex/base64）
  const injBytes = checkDataflow(
    wrap({
      bind: [{ var: "a", from: "A", source: "header", extract: { name: "X" } }],
      compute: [{ var: "mac", op: "hmac-sha256", args: [{ ref: "a" }, { ref: "a" }] }],
      inject: [{ var: "mac", into: "C", at: "url", name: "sig" }],
    }),
  );
  assert.ok(errorsOf(injBytes).includes("D9_type_mismatch"), "注入 bytes 应触发 D9");
  console.log("  ✓ 静态类型 bytes/text 不匹配被拒（D9）");
}

// ============ D10 🔒：字面量密钥被拒 ============
{
  const litKey = checkDataflow(
    wrap({
      bind: [{ var: "msg", from: "A", source: "header", extract: { name: "X" } }],
      compute: [{ var: "mac", op: "hmac-sha256", args: [{ text: "secret" }, { ref: "msg" }] }],
    }),
  );
  assert.ok(errorsOf(litKey).includes("D10_literal_key_forbidden"), "hmac 字面量 key 应触发 D10");
  const litIkm = checkDataflow(
    wrap({
      compute: [
        {
          var: "k",
          op: "hkdf",
          args: [{ text: "ikm" }, { text: "" }, { text: "info" }],
          params: { length: 32 },
        },
      ],
    }),
  );
  assert.ok(errorsOf(litIkm).includes("D10_literal_key_forbidden"), "hkdf 字面量 ikm 应触发 D10");
  console.log("  ✓ 🔒 字面量密钥被拒（D10）");
}

// ============ D11：复杂度限额 ============
{
  // 超节点数
  const manyBinds = Array.from({ length: MAX_DATAFLOW_NODES + 1 }, (_, i) => ({
    var: `b${i}`,
    from: "A",
    source: "header" as const,
    extract: { name: `H${i}` },
  }));
  const nodes = checkDataflow(wrap({ bind: manyBinds }));
  assert.ok(errorsOf(nodes).includes("D11_too_many_nodes"), "超节点数应触发 D11");
  // 超深度：链式 concat 叠 MAX_COMPUTE_DEPTH+1 层
  const chain: Array<{ var: string; op: string; args: Array<{ ref?: string; text?: string }> }> = [
    { var: "c0", op: "concat", args: [{ ref: "base" }, { text: "x" }] },
  ];
  for (let i = 1; i <= MAX_COMPUTE_DEPTH + 1; i++) {
    chain.push({ var: `c${i}`, op: "concat", args: [{ ref: `c${i - 1}` }, { text: "x" }] });
  }
  const deep = checkDataflow(
    wrap({
      bind: [{ var: "base", from: "A", source: "header", extract: { name: "X" } }],
      compute: chain,
    }),
  );
  assert.ok(errorsOf(deep).includes("D11_too_deep"), "超深度应触发 D11");
  console.log("  ✓ 复杂度限额（节点数 / 深度）（D11）");
}

// ============ D12：inject 目标 / var / 汇聚点查重 ============
{
  const unknownInto = checkDataflow(
    wrap({
      bind: [{ var: "a", from: "A", source: "header", extract: { name: "X" } }],
      inject: [{ var: "a", into: "ZZZ", at: "url", name: "p" }],
    }),
  );
  assert.ok(errorsOf(unknownInto).includes("D12_inject_unknown_request"), "未知 into 应触发 D12");
  const undefVar = checkDataflow(wrap({ inject: [{ var: "ghost", into: "C", at: "url", name: "p" }] }));
  assert.ok(errorsOf(undefVar).includes("D12_inject_undefined_var"), "未定义 var 应触发 D12");
  const dupSink = checkDataflow(
    wrap({
      bind: [
        { var: "a", from: "A", source: "header", extract: { name: "X" } },
        { var: "b", from: "B", source: "header", extract: { name: "Y" } },
      ],
      inject: [
        { var: "a", into: "C", at: "url", name: "p" },
        { var: "b", into: "C", at: "url", name: "p" },
      ],
    }),
  );
  assert.ok(errorsOf(dupSink).includes("D12_duplicate_sink"), "汇聚点重复应触发 D12");
  console.log("  ✓ inject 目标 / var / 汇聚点查重（D12）");
}

// ============ D13 🔒：信任门正向允许表 ============
{
  // 假想的生产第三方档（不在允许表）
  const thirdParty = checkDataflow({
    trustTier: "community",
    capabilities: [
      {
        id: "grades.list",
        requestGraph: "declarative",
        requests: [{ key: "A" }],
        bind: [{ var: "x", from: "A", source: "header", extract: { name: "X" } }],
      },
    ],
  });
  assert.ok(errorsOf(thirdParty).includes("D13_dataflow_trust_tier"), "非允许档应触发 D13");
  // official 与 sideload 均放行
  for (const tier of ["official", "sideload"]) {
    const ok = checkDataflow(
      wrap(
        {
          bind: [{ var: "x", from: "A", source: "header", extract: { name: "X" } }],
          inject: [{ var: "x", into: "C", at: "url", name: "p" }],
        },
        tier,
      ),
    );
    assert.ok(!errorsOf(ok).includes("D13_dataflow_trust_tier"), `${tier} 不应触发 D13`);
  }
  console.log("  ✓ 🔒 信任门正向允许表：新档不自动继承（D13，ADR-023 §2.6 防扩散）");
}

// ============ D15：请求依赖成环 ============
{
  // 取 C 的响应值注入 C 自身 = 自环
  const selfLoop = checkDataflow(
    wrap({
      bind: [{ var: "x", from: "C", source: "header", extract: { name: "X" } }],
      inject: [{ var: "x", into: "C", at: "url", name: "p" }],
    }),
  );
  assert.ok(errorsOf(selfLoop).includes("D15_request_cycle"), "自环应触发 D15");
  // 互环：A 的值注入 B、B 的值注入 A
  const mutual = checkDataflow(
    wrap({
      bind: [
        { var: "fa", from: "A", source: "header", extract: { name: "X" } },
        { var: "fb", from: "B", source: "header", extract: { name: "Y" } },
      ],
      inject: [
        { var: "fa", into: "B", at: "url", name: "p" },
        { var: "fb", into: "A", at: "url", name: "q" },
      ],
    }),
  );
  assert.ok(errorsOf(mutual).includes("D15_request_cycle"), "互环应触发 D15");
  console.log("  ✓ 请求依赖成环被拒（D15）");
}

// ============ D16 🔒：凭证头 / 逐跳头不得注入 ============
{
  for (const header of ["Cookie", "authorization", "Set-Cookie", "Host", "Content-Length"]) {
    const f = checkDataflow(
      wrap({
        bind: [{ var: "x", from: "A", source: "header", extract: { name: "X" } }],
        inject: [{ var: "x", into: "C", at: "header", name: header }],
      }),
    );
    assert.ok(errorsOf(f).includes("D16_forbidden_inject_header"), `注入 ${header} 应触发 D16`);
  }
  // 同名但 at=url 不受 D16 约束（query 参数叫 authorization 无害）
  const asQuery = checkDataflow(
    wrap({
      bind: [{ var: "x", from: "A", source: "header", extract: { name: "X" } }],
      inject: [{ var: "x", into: "C", at: "url", name: "authorization" }],
    }),
  );
  assert.ok(!errorsOf(asQuery).includes("D16_forbidden_inject_header"), "at=url 不应触发 D16");
  console.log("  ✓ 🔒 凭证头 / 逐跳头不得注入（D16，红线 #1）");
}

// ============ D14：死句柄 → warn（非 error）============
{
  const findings = checkDataflow(
    wrap({ bind: [{ var: "dead", from: "A", source: "header", extract: { name: "X" } }] }),
  );
  assert.ok(codes(findings).includes("D14_unused_handle"), "死句柄应触发 D14");
  assert.ok(!errorsOf(findings).includes("D14_unused_handle"), "D14 应为 warn 而非 error");
  console.log("  ✓ 死句柄 → warn（D14）");
}

console.log("\ndataflow smoke 全部通过。");
