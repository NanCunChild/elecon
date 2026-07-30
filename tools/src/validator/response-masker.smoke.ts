/** Response Masker 契约与 manifest 组合校验 golden（ADR-026，红线 #1/#5/#6）。 */

import { strict as assert } from "node:assert";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import {
  checkResponseMasker,
  type ResponseMaskerManifest,
  type ResponseMaskerPolicy,
} from "./response-masker.js";
import { loadContract, validateAdapterDir } from "./index.js";

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

for (const testCase of golden.cases) {
  const actual = [
    ...new Set(checkResponseMasker(testCase.policy, golden.manifest, validate).map((finding) => finding.code)),
  ].sort();
  const expected = [...testCase.expectedCodes].sort();
  assert.deepEqual(actual, expected, testCase.name);
  console.log(`  ✓ ${testCase.name}`);
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
          required: true,
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
  const policy = golden.cases[0]!.policy;
  const malformed = {
    trustTier: "official",
    network: { allow: [null] },
    capabilities: [null],
  } as unknown as ResponseMaskerManifest;
  assert.doesNotThrow(() => checkResponseMasker(policy, malformed, validate));
  console.log("  ✓ 畸形 manifest 不导致 Masker validator 崩溃");
}

// 旧 host 尚不能理解 Masker 最低版本门时，目录级发布校验必须 fail-closed。
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
            required: true,
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
    const codes = validateAdapterDir(dir, loadContract()).map((finding) => finding.code);
    assert.ok(codes.includes("RM0_host_gate_unavailable"));
    console.log("  ✓ host gate 未落地时 masker bundle 被阻断");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`response-masker validator smoke: ${golden.cases.length} cases passed`);
