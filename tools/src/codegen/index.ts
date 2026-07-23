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
 * 生成产物（带 DO NOT EDIT 头）：
 *  - contract/generated/ts/*.d.ts —— 纯类型声明（零运行时）。TS 消费方以
 *    `import type { X } from "<相对路径>/x.js"` 引用（.js ↔ .d.ts 标准映射），
 *    tsc 只做类型解析、不参与 emit，故不受消费方 rootDir 约束。
 *  - contract/generated/dart/lib/*.dart —— Dart 包 `elecon_contract`（pubspec 手写、
 *    lib/ 全部生成）。client 以 path 依赖引用，UI 模型据此消除手写漂移。
 * 生成物入库；一致性由 CI 漂移闸门（重新生成 + git diff --exit-code）保证。
 */

import { mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const schemaDir = join(repoRoot, "contract", "schema");
const registryPath = join(repoRoot, "contract", "capability", "registry.json");
const stdlibPkgPath = join(repoRoot, "adapters", "_stdlib", "package.json");
const outTsDir = join(repoRoot, "contract", "generated", "ts");
const outDartDir = join(repoRoot, "contract", "generated", "dart", "lib");

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
  oneOf?: JsonSchema[];
  anyOf?: unknown;
  definitions?: Record<string, JsonSchema>;
  $defs?: Record<string, JsonSchema>;
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

function resolveRef(s: JsonSchema, root: JsonSchema): JsonSchema {
  if (!s.$ref) return s;
  const match = s.$ref.match(/^#\/(?:\$defs|definitions)\/([^/]+)$/);
  if (!match) throw new Error(`不支持 $ref（外部引用）：${s.$ref}`);
  const resolved = (root.$defs ?? root.definitions)?.[match[1]!];
  if (!resolved) throw new Error(`找不到 $ref：${s.$ref}`);
  return resolved;
}

function assertSupported(s: JsonSchema, ctx: string): void {
  if (s.allOf || s.anyOf) throw new Error(`${ctx}: 不支持 allOf/anyOf（需人工处理）`);
}

/**
 * 枚举 schema 内缺 `description` 的 `properties` 字段（含嵌套 object / array item）。
 * 返回点分路径列表。契约风格规范：每字段必有 description（docs/rules/schema_style.md §2）。
 * description 可写在引用处或 `$defs` 定义处任一。$ref 环用 seenDefs 防无限递归。
 */
export function collectMissingDescriptions(root: JsonSchema): string[] {
  const missing: string[] = [];
  const seenDefs = new Set<string>();

  const walkNode = (s: JsonSchema, path: string, refName?: string): void => {
    if (refName) {
      const m = refName.match(/^#\/(?:\$defs|definitions)\/([^/]+)$/);
      if (m) {
        if (seenDefs.has(m[1]!)) return;
        seenDefs.add(m[1]!);
      }
    }
    if (s.type === "object" && s.properties) {
      for (const [key, raw] of Object.entries(s.properties)) {
        const child = raw.$ref ? resolveRef(raw, root) : raw;
        const p = path ? `${path}.${key}` : key;
        if (!(raw.description ?? child.description)) missing.push(p);
        walkNode(child, p, raw.$ref);
      }
    } else if (s.type === "array" && s.items) {
      const item = s.items.$ref ? resolveRef(s.items, root) : s.items;
      walkNode(item, `${path}[]`, s.items.$ref);
    }
  };

  walkNode(root, "");
  return missing;
}

// ---- TS 生成 ----

function tsType(
  s: JsonSchema,
  parentName: string,
  prop: string,
  emit: EmittedType[],
  root: JsonSchema,
): string {
  s = resolveRef(s, root);
  assertSupported(s, `${parentName}.${prop}`);
  if (s.oneOf) return s.oneOf.map((v) => tsType(v, parentName, prop, emit, root)).join(" | ");
  if (s.enum) return s.enum.map((e) => JSON.stringify(e)).join(" | ");
  switch (s.type) {
    case "string":
      return "string";
    case "number":
    case "integer":
      return "number";
    case "boolean":
      return "boolean";
    case "array": {
      const item = s.items ?? {};
      return `${tsType(item, parentName, prop, emit, root)}[]`;
    }
    case "object": {
      const name = parentName + pascalCase(prop);
      emit.push({ name, schema: s });
      return name;
    }
    default:
      return "unknown"; // 空 {} —— value 无约束
  }
}

function tsInterface(name: string, s: JsonSchema, emit: EmittedType[], root: JsonSchema): string {
  const required = new Set(s.required ?? []);
  const props = s.properties ?? {};
  const lines = [`export interface ${name} {`];
  for (const [key, ps] of Object.entries(props)) {
    const opt = required.has(key) ? "" : "?";
    const doc = ps.description ? `  /** ${ps.description} */\n` : "";
    lines.push(`${doc}  ${key}${opt}: ${tsType(ps, name, key, emit, root)};`);
  }
  lines.push("}");
  return lines.join("\n");
}

export function generateTs(rootName: string, root: JsonSchema): string {
  const blocks: string[] = [];
  // 先生成根，过程中把嵌套 object 推入 emit，再依次生成（可能再产生嵌套）。
  const rendered = new Set<string>();
  const queue: EmittedType[] = [{ name: rootName, schema: root }];
  while (queue.length) {
    const t = queue.shift()!;
    if (rendered.has(t.name)) continue;
    rendered.add(t.name);
    const childEmit: EmittedType[] = [];
    blocks.push(tsInterface(t.name, t.schema, childEmit, root));
    for (const c of childEmit) if (!rendered.has(c.name)) queue.push(c);
  }
  return `${blocks.join("\n\n")}\n`;
}

// ---- Dart 生成 ----

function dartType(s: JsonSchema, parentName: string, prop: string, root: JsonSchema): string {
  s = resolveRef(s, root);
  assertSupported(s, `${parentName}.${prop}`);
  if (s.oneOf) return "Object";
  if (s.enum) return "String"; // enum 以 String 承载（保持与 schema 校验一致，避免解析期抛错）
  switch (s.type) {
    case "string":
      return "String";
    case "number":
      return "num";
    case "integer":
      return "int";
    case "boolean":
      return "bool";
    case "array": {
      const item = s.items ?? {};
      return `List<${dartType(item, parentName, prop, root)}>`;
    }
    case "object":
      return parentName + pascalCase(prop);
    default:
      return "Object?";
  }
}

function dartClass(name: string, s: JsonSchema, root: JsonSchema): { code: string; children: EmittedType[] } {
  const required = new Set(s.required ?? []);
  const props = s.properties ?? {};
  const children: EmittedType[] = [];
  const fields: string[] = [];
  const ctorParams: string[] = [];
  for (const [key, ps] of Object.entries(props)) {
    const opt = required.has(key);
    const dt = dartType(ps, name, key, root);
    // 收集需要单独生成的嵌套 object 类型。
    const resolved = resolveRef(ps, root);
    if (resolved.type === "object") {
      children.push({ name: name + pascalCase(key), schema: resolved });
    } else if (resolved.type === "array") {
      const item = resolveRef(resolved.items ?? {}, root);
      if (item.type === "object") children.push({ name: name + pascalCase(key), schema: item });
    }
    const nullable = opt ? "" : "?";
    if (ps.description) fields.push(`  /// ${ps.description}`);
    fields.push(`  final ${dt}${nullable} ${key};`);
    ctorParams.push(opt ? `    required this.${key},` : `    this.${key},`);
  }
  const code =
    ctorParams.length === 0
      ? [`class ${name} {`, `  const ${name}();`, "", ...fields, `}`].join("\n")
      : [`class ${name} {`, `  const ${name}({`, ...ctorParams, `  });`, "", ...fields, `}`].join("\n");
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
    const { code, children } = dartClass(t.name, t.schema, root);
    blocks.push(code);
    for (const c of children) if (!rendered.has(c.name)) queue.push(c);
  }
  return `${blocks.join("\n\n")}\n`;
}

/**
 * 从 `contract/capability/registry.json`（capability id 单源）生成 Dart 常量集合。
 *
 * 为何 codegen 而非手抄：客户端加载器在**编译期**需要合法 capability 集（catalog 不得引入
 * registry 之外的新能力，ADR-010 §3.3.2(a)）；客户端运行时读不到 registry.json，只能预埋。
 * 由 codegen 产出 → CI 漂移闸门（重生成 + git diff）保证与 registry 严格同步，杜绝手抄漂移。
 * （服务端 `validate.ts` 运行时 `loadRegistryIds()` 直接读文件，故无需 TS 产物。）
 */
export function generateCapabilityRegistryDart(): string {
  const reg = JSON.parse(readFileSync(registryPath, "utf-8")) as {
    capabilities: Record<string, unknown>;
  };
  const ids = Object.keys(reg.capabilities).sort();
  if (ids.length === 0) throw new Error("registry.json 无 capability——拒绝生成空集合");
  const entries = ids.map((id) => `  '${id}',`).join("\n");
  return `${DART_HEADER}/// 所有合法 capability id —— 契约单源 contract/capability/registry.json。
/// 客户端加载器据此拒绝 catalog 引入 registry 之外的新能力（ADR-010 §3.3.2(a)，红线 #6）。
const Set<String> kCapabilityIds = {
${entries}
};
`;
}

/**
 * 生成客户端 `stdlib_version.dart`：`kHostStdlibVersion` = 随 app 打包的 elecon:html stdlib 版本。
 *
 * 单源 = `adapters/_stdlib/package.json` 的 version（与 server 双端锁步，ADR-018 §2.4）。
 * 客户端运行时读不到该 package.json（stdlib 只是 vendored 的 html.bundle.js，无内嵌版本号），
 * 只能编译期预埋。由 codegen 产出 → CI 漂移闸门（重生成 + git diff）保证与 package.json 严格同步，
 * 杜绝手抄漂移。加载器的 stdlibMin 门据此 fail-closed（本端 < bundle 声明的 stdlibMin → 拒载）。
 */
export function generateStdlibVersionDart(): string {
  const pkg = JSON.parse(readFileSync(stdlibPkgPath, "utf-8")) as { version?: unknown };
  const v = pkg.version;
  if (typeof v !== "string" || !/^\d+\.\d+\.\d+$/.test(v)) {
    throw new Error(`adapters/_stdlib/package.json 的 version 非法（须 x.y.z）：${String(v)}`);
  }
  return `${DART_HEADER}/// 本端随 app 打包的 elecon:html stdlib 版本 —— 契约单源
/// adapters/_stdlib/package.json（与 server 双端锁步，ADR-018 §2.4 B-host）。
/// 加载器 stdlibMin 门据此 fail-closed：本端 < bundle manifest 声明的 stdlibMin → 拒载。
const String kHostStdlibVersion = '${v}';
`;
}

// ---- 驱动 ----

const TS_HEADER =
  "// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。\n// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。\n\n";
const DART_HEADER =
  "// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。\n// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。\n\nlibrary;\n\n";

interface GenFile {
  schemaFile: string;
  typeName: string;
  ts: string;
  dart: string;
}

export function generateAll(): { files: GenFile[]; skipped: { file: string; reason: string }[] } {
  const out: GenFile[] = [];
  const skipped: { file: string; reason: string }[] = [];
  for (const file of readdirSync(schemaDir)
    .filter((f) => f.endsWith(".schema.json"))
    .sort()) {
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
    // description 门（docs/rules/schema_style.md §2）：默认只报告（给出 backfill 规模）；
    // 传 --require-descriptions 才硬失败——backfill 完成后 CI 切到该 flag 强制。
    const requireDesc = process.argv.includes("--require-descriptions");
    const misses: { file: string; path: string }[] = [];
    for (const file of readdirSync(schemaDir)
      .filter((f) => f.endsWith(".schema.json"))
      .sort()) {
      const schema = JSON.parse(readFileSync(join(schemaDir, file), "utf-8")) as JsonSchema;
      if (schema.type !== "object") continue;
      for (const p of collectMissingDescriptions(schema)) misses.push({ file, path: p });
    }
    if (misses.length === 0) {
      console.log("✓ description 全覆盖");
    } else {
      console.log(
        `\n⚠ description 缺失 ${misses.length} 处（每 properties 字段须有 description，见 docs/rules/schema_style.md §2）：`,
      );
      for (const m of misses) console.log(`  ✗ ${m.file}  ${m.path}`);
    }
    console.log(`\ncodegen --check：${files.length} 个 schema 可生成，${skipped.length} 个需人工处理。`);
    if (skipped.length > 0) process.exitCode = 1;
    if (requireDesc && misses.length > 0) process.exitCode = 1;
    return;
  }

  mkdirSync(outTsDir, { recursive: true });
  mkdirSync(outDartDir, { recursive: true });
  for (const f of files) {
    const base = f.schemaFile.replace(/\.schema\.json$/, "");
    writeFileSync(join(outTsDir, `${base}.d.ts`), f.ts);
    writeFileSync(join(outDartDir, `${base.replace(/\./g, "_")}.dart`), f.dart);
    console.log(`✓ ${f.schemaFile} → ${f.typeName}`);
  }
  writeFileSync(join(outDartDir, "capability_registry.dart"), generateCapabilityRegistryDart());
  console.log("✓ capability/registry.json → kCapabilityIds");
  writeFileSync(join(outDartDir, "stdlib_version.dart"), generateStdlibVersionDart());
  console.log("✓ adapters/_stdlib/package.json → kHostStdlibVersion");
  console.log(
    `\n生成 ${files.length} 个类型到 contract/generated/{ts,dart}/${skipped.length ? `（${skipped.length} 个需人工处理）` : ""}。`,
  );
}

// 仅在被直接执行时跑 CLI；被 import（如 smoke 测试）时不触发。
const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
