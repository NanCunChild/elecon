/** Response Masker 契约与 manifest 组合校验 golden（ADR-026，红线 #1/#5/#6）。 */

import { strict as assert } from "node:assert";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { loadContract, validateAdapterDir } from "./index.js";
import {
  checkResponseMasker,
  type ResponseMaskerManifest,
  type ResponseMaskerPolicy,
} from "./response-masker.js";

interface GoldenCase {
  name: string;
  policy: ResponseMaskerPolicy;
  expectedCodes: string[];
}

interface Golden {
  manifest: ResponseMaskerManifest;
  cases: GoldenCase[];
}

const contractRoot = fileURLToPath(new URL("../../../contract/", import.meta.url));
const schema = JSON.parse(readFileSync(`${contractRoot}response-masker.schema.json`, "utf8")) as object;
const golden = JSON.parse(
  readFileSync(`${contractRoot}golden/broker/response-masker-validator.json`, "utf8"),
) as Golden;

const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validate = ajv.compile(schema);

// 旧 validator golden 不在本次决策范围内；移除其中已废止的 required:true，保留
// required:false 用例以继续证明 optional/required 字段均被 schema 封闭。
function withoutLegacyRequired(policy: ResponseMaskerPolicy): unknown {
  return JSON.parse(
    JSON.stringify(policy, (key, value: unknown) =>
      key === "required" && value === true ? undefined : value,
    ),
  ) as unknown;
}

for (const testCase of golden.cases) {
  const actual = [
    ...new Set(
      checkResponseMasker(withoutLegacyRequired(testCase.policy), golden.manifest, validate).map(
        (finding) => finding.code,
      ),
    ),
  ].sort();
  const expected = [...testCase.expectedCodes].sort();
  assert.deepEqual(actual, expected, testCase.name);
  console.log(`  ✓ ${testCase.name}`);
}

{
  const findings = checkResponseMasker({ schemaVersion: 1, rules: [] }, golden.manifest, validate);
  assert.deepEqual(findings, []);
  console.log("  ✓ 空 rules policy 合法");
}

// 通配 acquisition scope 必须做集合包含，不能用单个 witness URL 代替证明。
{
  const policy = {
    schemaVersion: 1,
    rules: [
      {
        id: "wildcard-containment",
        match: {
          capability: "notice.list",
          method: "GET",
          urlScope: "https://api.example.edu/a*",
        },
        capture: {
          source: "header",
          name: "X-Synthetic-Secret",
          exactly: 1,
          destination: { kind: "redact" },
        },
        project: "delete",
      },
    ],
  };
  const manifest = {
    ...golden.manifest,
    network: { allow: ["https://api.example.edu/a__elecon_masker_scope_probe__"] },
  };
  const codes = checkResponseMasker(policy, manifest, validate).map((finding) => finding.code);
  assert.ok(codes.includes("RM5_source_outside_allow"));
  console.log("  ✓ wildcard acquisition scope 使用集合包含判定");
}

// manifest schema 另行报告形状错误；Masker 组合校验自身不得因缺字段抛异常。
{
  const policy = withoutLegacyRequired(golden.cases[0]!.policy);
  const malformed = {
    trustTier: "official",
    network: { allow: [null] },
    capabilities: [null],
  } as unknown as ResponseMaskerManifest;
  assert.doesNotThrow(() => checkResponseMasker(policy, malformed, validate));
  console.log("  ✓ 畸形 manifest 不导致 Masker validator 崩溃");
}

// bundleFormat `/3` 断代后（ADR-026 §2.7.1）：合法 masker bundle 放行、缺 masker.json 的 official 拒、sideload 不要求。
{
  const dir = mkdtempSync(join(tmpdir(), "elecon-masker-validator-"));
  try {
    const manifest = {
      manifestVersion: "1.0",
      adapterId: "school-masker-synthetic",
      adapterVersion: "1.0.0",
      schoolId: "masker-synthetic",
      displayName: "Masker Synthetic",
      trustTier: "official",
      runtime: { engine: "quickjs", entry: "index.js" },
      network: { allow: ["https://api.example.edu/*"] },
      capabilities: [
        {
          id: "notice.list",
          emits: { schema: "elecon.notice.list", schemaVersion: "1.1" },
          requestGraph: "imperative",
        },
      ],
    };
    const policy = {
      schemaVersion: 1,
      rules: [
        {
          id: "synthetic-redact",
          match: {
            capability: "notice.list",
            method: "GET",
            urlScope: "https://api.example.edu/notices",
          },
          capture: {
            source: "header",
            name: "X-Synthetic-Secret",
            exactly: 1,
            destination: { kind: "redact" },
          },
          project: "delete",
        },
      ],
    };
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
    writeFileSync(join(dir, "masker.json"), JSON.stringify(policy));
    writeFileSync(join(dir, "index.js"), "export function notice_list() {}\n");
    const findings = validateAdapterDir(dir, loadContract());
    const codes = findings.map((finding) => finding.code);
    const errorCodes = findings.filter((finding) => finding.level === "error").map((finding) => finding.code);
    assert.ok(!codes.includes("RM0_host_gate_unavailable"), "RM0_host_gate_unavailable 已随 /3 断代退役");
    assert.ok(
      !errorCodes.some((code) => code.startsWith("RM")),
      `合法 masker bundle 不应有 error 级 RM* finding：${errorCodes.join(",")}`,
    );
    assert.ok(
      findings.some(
        (finding) => finding.code === "RM18_header_source_server_unattested" && finding.level === "warn",
      ),
      `header 源规则须有 RM18 warn（服务端运行时不可执行）：${codes.join(",")}`,
    );
    console.log("  ✓ /3 断代后合法 masker bundle 放行（无 error 级 RM；header 源规则带 RM18 warn）");

    // P1-08 前：handle 目标规则的投影义务无运行时执行方 → 发布门 RM17 error 禁签。
    const handlePolicy = {
      schemaVersion: 1,
      rules: [
        {
          id: "synthetic-handle",
          match: {
            capability: "notice.list",
            method: "GET",
            urlScope: "https://api.example.edu/notices",
          },
          capture: { exactly: 1, destination: { kind: "handle", ref: "csrf" } },
          project: "replace",
        },
      ],
    };
    writeFileSync(join(dir, "masker.json"), JSON.stringify(handlePolicy));
    const handleFindings = validateAdapterDir(dir, loadContract());
    assert.ok(
      handleFindings.some(
        (finding) => finding.code === "RM17_handle_target_unsupported" && finding.level === "error",
      ),
      `handle 目标规则须 RM17 error：${handleFindings.map((finding) => finding.code).join(",")}`,
    );
    console.log("  ✓ handle 目标规则 → RM17_handle_target_unsupported（P1-08 前禁签）");
    writeFileSync(join(dir, "masker.json"), JSON.stringify(policy));

    // official 缺 masker.json → RM0_policy_missing（缺文件 ≠ 空规则）。
    rmSync(join(dir, "masker.json"));
    const missing = validateAdapterDir(dir, loadContract()).map((finding) => finding.code);
    assert.ok(
      missing.includes("RM0_policy_missing"),
      `official 缺 masker.json 须 RM0_policy_missing：${missing.join(",")}`,
    );
    console.log("  ✓ official 缺 masker.json → RM0_policy_missing");

    // 空规则合法：{"schemaVersion":1,"rules":[]} 放行。
    writeFileSync(join(dir, "masker.json"), JSON.stringify({ schemaVersion: 1, rules: [] }));
    const empty = validateAdapterDir(dir, loadContract()).map((finding) => finding.code);
    assert.ok(!empty.some((code) => code.startsWith("RM")), `空规则 masker.json 应放行：${empty.join(",")}`);
    console.log("  ✓ official 空规则 masker.json 放行");

    // sideload 不要求 masker.json（缺则无 RM0），带了则 RM2 拒。
    rmSync(join(dir, "masker.json"));
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({ ...manifest, trustTier: "sideload" }));
    const sideloadMissing = validateAdapterDir(dir, loadContract(), "sideload").map(
      (finding) => finding.code,
    );
    assert.ok(
      !sideloadMissing.includes("RM0_policy_missing"),
      "sideload 缺 masker.json 不报 RM0_policy_missing",
    );
    writeFileSync(join(dir, "masker.json"), JSON.stringify(policy));
    const sideloadPresent = validateAdapterDir(dir, loadContract(), "sideload").map(
      (finding) => finding.code,
    );
    assert.ok(sideloadPresent.includes("RM2_official_only"), "sideload 带 masker.json 须 RM2_official_only");
    console.log("  ✓ sideload：缺 masker.json 不报、带则 RM2 拒");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`response-masker validator smoke: ${golden.cases.length} cases passed`);
