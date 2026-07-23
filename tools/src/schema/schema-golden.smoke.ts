/**
 * 核心 schema 行为 golden。
 *
 * codegen 漂移只能证明类型产物同步；这里固定合法样本和 required 字段拒绝，
 * 防止 schema 在扩展时出现“能生成但语义变宽/变窄”的静默回归。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function validatorFor(schemaName: string) {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv.compile(readJson<object>(join(repoRoot, "contract/schema", `${schemaName}.schema.json`)));
}

function requiredField(schemaName: string): string {
  const schema = readJson<{ required?: string[] }>(
    join(repoRoot, "contract/schema", `${schemaName}.schema.json`),
  );
  assert.ok(schema.required?.length, `${schemaName} 应至少有一个 required 字段`);
  return schema.required[0]!;
}

const cases: Array<{ schema: string; valid: unknown }> = [
  {
    schema: "notice.list",
    valid: readJson<{ expected: unknown }>(`${repoRoot}adapters/school-xidian/fixtures/notice.list.json`)
      .expected,
  },
  {
    schema: "grades.list",
    valid: readJson<{ expected: unknown }>(
      `${repoRoot}adapters/_template/declarative/fixtures/grades.list.json`,
    ).expected,
  },
  {
    schema: "schedule.week",
    valid: {
      term: "2025-2026-2",
      week: 1,
      days: [{ dayOfWeek: 1, slots: [{ start: "08:00", end: "09:40", courseName: "示例课程" }] }],
    },
  },
  {
    schema: "card.balance",
    valid: { cardNumber: "****1234", balance: { amountMinor: 1250, currency: "CNY" } },
  },
  {
    schema: "card.transactions",
    valid: {
      cardNumber: "****1234",
      items: [{ time: "2026-01-01T00:00:00Z", amountMinor: 250, currency: "CNY", direction: "debit" }],
    },
  },
  {
    schema: "library.loans",
    valid: {
      items: [
        {
          bookId: "BOOK-001",
          title: "示例图书",
          borrowedAt: "2026-01-01T00:00:00Z",
          dueAt: "2026-02-01T00:00:00Z",
        },
      ],
    },
  },
  {
    schema: "generic.section",
    valid: { sectionId: "energy", title: "能源", fields: [{ label: "用量", role: "quantity", value: 12 }] },
  },
];

async function main(): Promise<void> {
  for (const testCase of cases) {
    const validate = validatorFor(testCase.schema);
    assert.ok(
      validate(testCase.valid),
      `${testCase.schema} 合法 golden 未通过：${JSON.stringify(validate.errors)}`,
    );

    const invalid = { ...(testCase.valid as Record<string, unknown>) };
    delete invalid[requiredField(testCase.schema)];
    assert.equal(validate(invalid), false, `${testCase.schema} 缺少 required 字段却通过`);
  }
  console.log(`schema golden smoke：${cases.length} 个 schema 合法/非法样本全部通过 ✅`);
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
