/**
 * codegen 冒烟测试 —— 针对 pascalCase / generateTs / generateDart 的纯逻辑断言。
 * 端到端生成由 `npm run codegen` 对真实 contract/schema/ 跑。
 *
 *   运行：cd tools && npm run smoke:codegen
 */

import { strict as assert } from "node:assert";
import { pascalCase, generateTs, generateDart } from "./index.js";

// ---- pascalCase ----

assert.strictEqual(pascalCase("elecon.notice.list"), "NoticeList");
assert.strictEqual(pascalCase("notice.list.schema.json"), "NoticeList");
assert.strictEqual(pascalCase("elecon.card.transactions"), "CardTransactions");
assert.strictEqual(pascalCase("elecon.params.grades.list"), "ParamsGradesList");
console.log("✓ pascalCase");

// ---- generateTs：notice.list 形状 ----

const noticeSchema = {
  $id: "elecon.notice.list",
  type: "object",
  required: ["items"],
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        required: ["id", "title", "category", "source"],
        properties: {
          id: { type: "string" },
          title: { type: "string" },
          summary: { type: "string" },
          publishedAt: { type: "string", format: "date-time" },
          category: { type: "string", enum: ["academic", "admin", "event", "unknown"] },
          source: { type: "string" },
        },
      },
    },
  },
};

{
  const ts = generateTs("NoticeList", noticeSchema);
  assert.ok(ts.includes("export interface NoticeList {"), "应有 NoticeList 接口");
  assert.ok(ts.includes("items: NoticeListItems[];"), "items 应为数组 of 具名类型");
  assert.ok(ts.includes("export interface NoticeListItems {"), "应生成嵌套 item 类型");
  assert.ok(ts.includes("id: string;"), "required id 非可选");
  assert.ok(ts.includes("summary?: string;"), "非 required summary 应可选");
  assert.ok(
    ts.includes('category: "academic" | "admin" | "event" | "unknown";'),
    "enum 应生成 union",
  );
  console.log("✓ generateTs（object/array/enum/optional）");
}

// ---- generateDart ----

{
  const dart = generateDart("NoticeList", noticeSchema);
  assert.ok(dart.includes("class NoticeList {"), "应有 NoticeList class");
  assert.ok(dart.includes("class NoticeListItems {"), "应生成嵌套 item class");
  assert.ok(dart.includes("final List<NoticeListItems> items;"), "items 为 List of 具名类型");
  assert.ok(dart.includes("final String id;"), "required id 非空");
  assert.ok(dart.includes("final String? summary;"), "非 required summary 应可空");
  assert.ok(dart.includes("required this.items,"), "required 字段构造用 required");
  assert.ok(dart.includes("this.summary,"), "可选字段构造不带 required");
  console.log("✓ generateDart（object/array/nullable）");
}

// ---- 不支持构造应报错（不静默生成错类型） ----

{
  assert.throws(
    () => generateTs("X", { type: "object", properties: { a: { $ref: "other" } } }),
    /不支持 \$ref/,
    "$ref 应抛错",
  );
  assert.throws(
    () => generateDart("X", { type: "object", properties: { a: { oneOf: [] } } }),
    /不支持 allOf\/oneOf\/anyOf/,
    "oneOf 应抛错",
  );
  console.log("✓ 不支持构造报错（$ref / oneOf）");
}

console.log("\ncodegen smoke 全部通过 ✅");
