/**
 * validator 冒烟测试 —— 针对 checkManifest 的纯逻辑断言（不碰文件系统）。
 * 端到端（含 fixtures C5）由 `npm run validate` 对真实模板验证。
 *
 *   运行：cd tools && npm run smoke:validator
 */

import { strict as assert } from "node:assert";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

import { checkManifest } from "./index.js";

// 一个最小的、宽松的 manifest schema 桩：只验我们关心的字段存在性，
// 让 C2/C3/C4 的逻辑断言不被 C1 噪声淹没。
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const manifestValidate = ajv.compile({ type: "object" });

const registry = {
  "grades.list": { emits: { schema: "elecon.grades.list", schemaVersion: "1.0" } },
};

const contract = { manifestValidate, registry };

function codes(findings: { code: string }[]): string[] {
  return findings.map((f) => f.code);
}

// 1) sideload + fetch → C3
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "sideload",
      mode: "fetch",
      network: { allow: ["https://h/api/*"] },
      capabilities: [{ id: "grades.list", emits: { schema: "elecon.grades.list", schemaVersion: "1.0" } }],
    },
    contract,
  );
  assert.ok(codes(findings).includes("C3_sideload_must_parser"), "sideload+fetch 应触发 C3");
  console.log("  ✓ sideload + fetch 被拒（C3）");
}

// 2) 未注册 capability → C2
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "official",
      mode: "fetch",
      network: { allow: ["https://h/api/*"] },
      capabilities: [{ id: "ghost.cap", emits: { schema: "elecon.ghost", schemaVersion: "1.0" } }],
    },
    contract,
  );
  assert.ok(codes(findings).includes("C2_unregistered_capability"), "未注册 capability 应触发 C2");
  console.log("  ✓ 未注册 capability 被拒（C2）");
}

// 3) parser request 越出白名单 → C4
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "sideload",
      mode: "parser",
      network: { allow: ["https://allowed.edu/api/*"] },
      capabilities: [
        {
          id: "grades.list",
          emits: { schema: "elecon.grades.list", schemaVersion: "1.0" },
          requests: [{ key: "raw", method: "GET", url: "https://evil.example/api/x?t={term}" }],
        },
      ],
    },
    contract,
  );
  assert.ok(codes(findings).includes("C4_request_outside_allow"), "越界 request 应触发 C4");
  console.log("  ✓ request 越出白名单被拒（C4）");
}

// 4) emits 与 registry 漂移 → C2_emits_mismatch
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "official",
      mode: "fetch",
      network: { allow: ["https://h/api/*"] },
      capabilities: [{ id: "grades.list", emits: { schema: "elecon.grades.list", schemaVersion: "2.0" } }],
    },
    contract,
  );
  assert.ok(codes(findings).includes("C2_emits_mismatch"), "emits 版本漂移应触发 C2_emits_mismatch");
  console.log("  ✓ emits 与 registry 漂移被拒（C2）");
}

// 5) 合法 parser（request 命中白名单，且占位符不干扰）→ 无 error
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "sideload",
      mode: "parser",
      network: { allow: ["https://jw.example.edu.cn/api/*"] },
      capabilities: [
        {
          id: "grades.list",
          emits: { schema: "elecon.grades.list", schemaVersion: "1.0" },
          requests: [{ key: "raw", method: "GET", url: "https://jw.example.edu.cn/api/grades?term={term}" }],
        },
      ],
    },
    contract,
  );
  assert.equal(findings.filter((f) => f.level === "error").length, 0, `合法 parser 不应有 error：${JSON.stringify(findings)}`);
  console.log("  ✓ 合法 parser 通过（占位符不干扰白名单匹配）");
}

// 6) credential scope 越出 network.allow → C6
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "official",
      mode: "fetch",
      network: { allow: ["https://h/api/*"] },
      credentials: { session: { scope: ["https://evil/api/*"], type: "cookie" } },
      capabilities: [{ id: "grades.list", emits: { schema: "elecon.grades.list", schemaVersion: "1.0" } }],
    },
    contract,
  );
  assert.ok(codes(findings).includes("C6_scope_outside_allow"), "scope 越出 allow 应触发 C6");
  console.log("  ✓ credential scope 越出白名单被拒（C6）");
}

// 7) 不同凭证 scope 前缀等长且重叠 → C7
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "official",
      mode: "fetch",
      network: { allow: ["https://h/*"] },
      credentials: {
        a: { scope: ["https://h/api/*"], type: "cookie" },
        b: { scope: ["https://h/api/*"], type: "header" },
      },
      capabilities: [{ id: "grades.list", emits: { schema: "elecon.grades.list", schemaVersion: "1.0" } }],
    },
    contract,
  );
  assert.ok(codes(findings).includes("C7_ambiguous_credential_scope"), "等长重叠 scope 应触发 C7");
  console.log("  ✓ 等长重叠的凭证 scope 被拒（C7）");
}

// 8) parser request 引用未声明的 credential → C8
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "sideload",
      mode: "parser",
      network: { allow: ["https://h/api/*"] },
      capabilities: [
        {
          id: "grades.list",
          emits: { schema: "elecon.grades.list", schemaVersion: "1.0" },
          requests: [{ key: "raw", method: "GET", url: "https://h/api/x", credential: "session" }],
        },
      ],
    },
    contract,
  );
  assert.ok(codes(findings).includes("C8_undeclared_credential_ref"), "未声明 credential 引用应触发 C8");
  console.log("  ✓ parser 引用未声明 credential 被拒（C8）");
}

// 9) 合法 fetch + credentials：不同长度前缀重叠由最长前缀消解，非错误
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "official",
      mode: "fetch",
      network: { allow: ["https://h/*"] },
      credentials: {
        broad: { scope: ["https://h/*"], type: "cookie" },
        api: { scope: ["https://h/api/*"], type: "header" },
      },
      capabilities: [{ id: "grades.list", emits: { schema: "elecon.grades.list", schemaVersion: "1.0" } }],
    },
    contract,
  );
  assert.equal(
    findings.filter((f) => f.level === "error").length,
    0,
    `不同长度前缀重叠不应报错（最长前缀消解）：${JSON.stringify(findings)}`,
  );
  console.log("  ✓ 不同长度前缀重叠由最长前缀消解，不报错（C7 不误杀）");
}

// 10) parser 声明了 credential 但无 request 引用 → C8_unused_credential（warn，非 error）
{
  const findings = checkManifest(
    {
      adapterId: "school-x",
      trustTier: "sideload",
      mode: "parser",
      network: { allow: ["https://h/api/*"] },
      credentials: { session: { scope: ["https://h/api/*"], type: "cookie" } },
      capabilities: [
        {
          id: "grades.list",
          emits: { schema: "elecon.grades.list", schemaVersion: "1.0" },
          requests: [{ key: "raw", method: "GET", url: "https://h/api/x" }],
        },
      ],
    },
    contract,
  );
  const unused = findings.filter((f) => f.code === "C8_unused_credential");
  assert.equal(unused.length, 1, "声明未用的 credential 应触发 1 条 C8_unused_credential");
  assert.equal(unused[0]!.level, "warn", "C8_unused_credential 应为 warn 而非 error");
  assert.equal(findings.filter((f) => f.level === "error").length, 0, "声明未用不应产生 error");
  console.log("  ✓ parser 声明未用的 credential 仅告警不报错（C8 warn）");
}

console.log("validator smoke 全部通过。");
