/**
 * codegen：JSON Schema（contract/schema/，唯一事实来源）→ Dart / TS 类型。
 *
 * 宿主在边界处校验：客户端核心 Dart、服务端 TS（ajv）。生成 Dart 与 TS 两套类型供
 * 两端消费（ADR-001 §3.1，服务端语言见 ADR-005），消除手写模型与 schema 的漂移
 * （审阅发现：client/lib/ui/home 曾手写 15 个模型）。
 *
 * 支持的 schema 构造（覆盖当前 contract/schema/*）：object（required/optional）、
 * array、string/number/boolean、enum（→ TS union / Dart enum）、嵌套匿名 object
 * （按 父类型名+属性名 命名）、空 `{}`（→ unknown / Object?）。不支持 $ref / allOf
 * /oneOf——若出现则报错要求人工处理（避免静默生成错类型）。
 *
 *   运行：cd tools && npm run codegen                     # 生成全部
 *         cd tools && npm run codegen -- --check          # 仅校验（不写文件，CI 用）
 *
 * 生成产物：contract/generated/ts/*.ts、contract/generated/dart/*.dart（带 DO NOT EDIT 头）。
 */

import { readFileSync, readdirSync, writeFileSync, mkdirSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const schemaDir = join(repoRoot, "contract", "schema");
const outTsDir = join(repoRoot, "contract", "generated", "ts");
const outDartDir = join(repoRoot, "contract", "generated", "dart");

// ---- schema 类型 ----

interface JsonSchema {
  $id?: string;
  title?: string;
  type?: string;
  required?: string[];
  properties?: Record<string, JsonSchema>;
  items?: JsonSchema;
  enum?: string[];
  description?: string;
  $ref?: string;
  allOf?: unknown;
  oneOf?: unknown;
  anyOf?: unknown;
}

// ---- 命名 ----

/** "elecon.notice.list" / "notice.list.schema.json" → "NoticeList"。 */
export function pascalCase(id: string): string {
  return id
    .replace(/\.schema\.json$/, "")
    .replace(/^elecon\./, "")
    .split(/[.\-_]/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join("");
}

// 收集嵌套 object 生成的具名类型：name → schema。
interface EmittedType {
  name: string;
  schema: JsonSchema;
}

function assertSupported(s: JsonSchema, ctx: string): void {
  if (s.$ref) throw new Error(`${ctx}: 不支持 $ref（需人工处理）`);
  if (s.allOf || s.oneOf || s.anyOf) throw new Error(`${ctx}: 不支持 allOf/oneOf/anyOf（需人工处理）`);
}

// ---- TS 生成 ----

function tsType(s: JsonSchema, parentName: string, prop: string, emit: EmittedType[]): string {
  assertSupported(s, `${parentName}.${prop}`);
  if (s.enum) return s.enum.map((e) => JSON.stringify(e)).join(" | ");
  switch (s.type) {
    case "string": return "string";
    case "number":
    case "integer": return "number";
    case "boolean": return "boolean";
    case "array": {
      const item = s.items ?? {};
      return `${tsType(item, parentName, prop, emit)}[]`;
    }
    case "object": {
      const name = parentName + pascalCase(prop);
      emit.push({ name, schema: s });
      return name;
    }
    default: return "unknown"; // 空 {} —— value 无约束
  }
}

function tsInterface(name: string, s: JsonSchema, emit: EmittedType[]): string {
  const required = new Set(s.required ?? []);
  const props = s.properties ?? {};
  const lines = [`export interface ${name} {`];
  for (const [key, ps] of Object.entries(props)) {
    const opt = required.has(key) ? "" : "?";
    const doc = ps.description ? `  /** ${ps.description} */\n` : "";
    lines.push(`${doc}  ${key}${opt}: ${tsType(ps, name, key, emit)};`);
  }
  lines.push("}");
  return lines.join("\n");
}

export function generateTs(rootName: string, root: JsonSchema): string {
  const emit: EmittedType[] = [];
  const blocks: string[] = [];
  // 先生成根，过程中把嵌套 object 推入 emit，再依次生成（可能再产生嵌套）。
  const rendered = new Set<string>();
  const queue: EmittedType[] = [{ name: rootName, schema: root }];
  while (queue.length) {
    const t = queue.shift()!;
    if (rendered.has(t.name)) continue;
    rendered.add(t.name);
    const childEmit: EmittedType[] = [];
    blocks.push(tsInterface(t.name, t.schema, childEmit));
    for (const c of childEmit) if (!rendered.has(c.name)) queue.push(c);
  }
  return `${blocks.join("\n\n")}\n`;
}

// ---- Dart 生成 ----

function dartType(s: JsonSchema, parentName: string, prop: string): string {
  assertSupported(s, `${parentName}.${prop}`);
  if (s.enum) return "String"; // enum 以 String 承载（保持与 schema 校验一致，避免解析期抛错）
  switch (s.type) {
    case "string": return "String";
    case "number": return "num";
    case "integer": return "int";
    case "boolean": return "bool";
    case "array": {
      const item = s.items ?? {};
      return `List<${dartType(item, parentName, prop)}>`;
    }
    case "object": return parentName + pascalCase(prop);
    default: return "Object?";
  }
}

function dartClass(name: string, s: JsonSchema): { code: string; children: EmittedType[] } {
  const required = new Set(s.required ?? []);
  const props = s.properties ?? {};
  const children: EmittedType[] = [];
  const fields: string[] = [];
  const ctorParams: string[] = [];
  for (const [key, ps] of Object.entries(props)) {
    const opt = required.has(key);
    const dt = dartType(ps, name, key);
    // 收集需要单独生成的嵌套 object 类型。
    if (ps.type === "object") {
      children.push({ name: name + pascalCase(key), schema: ps });
    } else if (ps.type === "array" && ps.items?.type === "object") {
      children.push({ name: name + pascalCase(key), schema: ps.items });
    }
    const nullable = opt ? "" : "?";
    if (ps.description) fields.push(`  /// ${ps.description}`);
    fields.push(`  final ${dt}${nullable} ${key};`);
    ctorParams.push(opt ? `    required this.${key},` : `    this.${key},`);
  }
  const code = [
    `class ${name} {`,
    `  const ${name}({`,
    ...ctorParams,
    `  });`,
    "",
    ...fields,
    `}`,
  ].join("\n");
  return { code, children };
}

export function generateDart(rootName: string, root: JsonSchema): string {
  const blocks: string[] = [];
  const rendered = new Set<string>();
  const queue: EmittedType[] = [{ name: rootName, schema: root }];
  while (queue.length) {
    const t = queue.shift()!;
    if (rendered.has(t.name)) continue;
    rendered.add(t.name);
    const { code, children } = dartClass(t.name, t.schema);
    blocks.push(code);
    for (const c of children) if (!rendered.has(c.name)) queue.push(c);
  }
  return `${blocks.join("\n\n")}\n`;
}

// ---- 驱动 ----

const TS_HEADER = "// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。\n// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。\n\n";
const DART_HEADER = "// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。\n// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。\n\nlibrary;\n\n";

interface GenFile {
  schemaFile: string;
  typeName: string;
  ts: string;
  dart: string;
}

export function generateAll(): { files: GenFile[]; skipped: { file: string; reason: string }[] } {
  const out: GenFile[] = [];
  const skipped: { file: string; reason: string }[] = [];
  for (const file of readdirSync(schemaDir).filter((f) => f.endsWith(".schema.json")).sort()) {
    const schema = JSON.parse(readFileSync(join(schemaDir, file), "utf-8")) as JsonSchema;
    if (schema.type !== "object") continue; // 只为对象根生成
    const typeName = pascalCase(schema.$id ?? file);
    try {
      out.push({
        schemaFile: file,
        typeName,
        ts: TS_HEADER + generateTs(typeName, schema),
        dart: DART_HEADER + generateDart(typeName, schema),
      });
    } catch (err) {
      // 含不支持构造（$ref/oneOf/…）的 schema 跳过并记录——人工处理，不静默生成错类型。
      skipped.push({ file, reason: (err as Error).message });
    }
  }
  return { files: out, skipped };
}

function main(): void {
  const check = process.argv.includes("--check");
  const { files, skipped } = generateAll();

  for (const s of skipped) {
    console.log(`⚠ 跳过 ${s.file}：${s.reason}`);
  }

  if (check) {
    console.log(`codegen --check：${files.length} 个 schema 可生成，${skipped.length} 个需人工处理。`);
    if (skipped.length > 0) process.exitCode = 1;
    return;
  }

  mkdirSync(outTsDir, { recursive: true });
  mkdirSync(outDartDir, { recursive: true });
  for (const f of files) {
    const base = f.schemaFile.replace(/\.schema\.json$/, "");
    writeFileSync(join(outTsDir, `${base}.ts`), f.ts);
    writeFileSync(join(outDartDir, `${base.replace(/\./g, "_")}.dart`), f.dart);
    console.log(`✓ ${f.schemaFile} → ${f.typeName}`);
  }
  console.log(`\n生成 ${files.length} 个类型到 contract/generated/{ts,dart}/${skipped.length ? `（${skipped.length} 个需人工处理）` : ""}。`);
}

// 仅在被直接执行时跑 CLI；被 import（如 smoke 测试）时不触发。
const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
