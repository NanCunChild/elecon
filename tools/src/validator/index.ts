/**
 * adapter 校验器（CI 闸门）。契约校验用 ajv，与服务端共用同一套 schema。
 *
 * 检查项：
 *  C1 manifest 对 contract/manifest.schema.json 的合规性（ajv）
 *  C2 capability id ∈ registry.json，且 emits.schema/version 与 registry 一致（防漂移）
 *  C3 sideload 信任档**强制** parser 模式（拒绝 sideload + fetch，分发/签名路径，红线 #5）
 *  C4 网络白名单：fetch 模式须有 allow；parser 的每条 requests.url 须被 allow 覆盖
 *  C5 夹具：fixtures/*.json 的 expected 须通过该 capability 的 emits schema
 *  C6 凭证作用域：credentials.<name>.scope 每条须 ⊆ network.allow（ADR-013 §2.4 规则 1）
 *  C7 作用域消歧：不同凭证的 scope 前缀长度相同且重叠 → 拒绝（ADR-013 §2.4 规则 2 / ADR-009 §2.3b）
 *  C8 引用闭合：parser 的 requests.credential 须在 credentials 声明；声明未用 → warn（ADR-013 §2.4 规则 3）
 *  C9 凭证注入方式：credentials.<name>.type ∈ {cookie, header}（防御性，schema C1 亦拦）
 *
 * 尚未覆盖（留给优先级 #3 客户端落地）：
 *  - 完整 golden 双跑：客户端 QuickJS 与服务端 QuickJS-wasm 对同一夹具产出比对。
 *    服务端单引擎 golden 已由 server/src/runtime/sandbox.smoke.ts 证明。
 *    本校验器只做"夹具 expected 合 schema"这一不依赖沙箱的部分（见 C5）。
 *
 *   运行：cd tools && npm run validate                  # 校验 adapters/ 下全部
 *         cd tools && npm run validate -- --adapter=../adapters/_template/parser
 */

import { readFileSync, readdirSync, existsSync, statSync, realpathSync } from "node:fs";
import { join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020, type ValidateFunction } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const contractDir = join(repoRoot, "contract");
const adaptersRoot = join(repoRoot, "adapters");

// ---- 类型 ----

type Level = "error" | "warn";

interface Finding {
  level: Level;
  code: string;
  message: string;
}

interface RegistryEntry {
  emits: { schema: string; schemaVersion: string };
  params?: { schema: string; schemaVersion: string };
}

interface CapabilityDecl {
  id: string;
  emits: { schema: string; schemaVersion: string };
  params?: { schema: string; schemaVersion: string };
  requests?: Array<{ key: string; method: string; url: string; credential?: string }>;
}

interface CredentialDecl {
  scope: string[];
  type: "cookie" | "header";
}

interface Manifest {
  adapterId: string;
  trustTier: "official" | "sideload";
  mode: "fetch" | "parser";
  network: { allow: string[] };
  /** 凭证引用声明（ADR-013）。可选；缺省即无凭证注入。 */
  credentials?: Record<string, CredentialDecl>;
  capabilities: CapabilityDecl[];
}

interface Contract {
  manifestValidate: ValidateFunction;
  registry: Record<string, RegistryEntry>;
  /** 按 schema $id 取域 schema 的校验函数；未落盘的返回 undefined。 */
  schemaFor: (id: string) => ValidateFunction | undefined;
}

// ---- 契约加载 ----

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function loadContract(): Contract {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);

  const manifestSchema = readJson<Record<string, unknown>>(join(contractDir, "manifest.schema.json"));
  const manifestValidate = ajv.compile(manifestSchema);

  const registryRaw = readJson<{ capabilities: Record<string, RegistryEntry> }>(
    join(contractDir, "capability", "registry.json"),
  );

  // 把所有已落盘的域 schema 编进同一个 ajv，按 $id 索引
  const schemaDir = join(contractDir, "schema");
  for (const file of readdirSync(schemaDir)) {
    if (!file.endsWith(".schema.json")) continue;
    const schema = readJson<Record<string, unknown>>(join(schemaDir, file));
    const id = typeof schema.$id === "string" ? schema.$id : undefined;
    if (id && !ajv.getSchema(id)) {
      ajv.addSchema(schema);
    }
  }

  return {
    manifestValidate,
    registry: registryRaw.capabilities,
    schemaFor: (id) => ajv.getSchema(id) as ValidateFunction | undefined,
  };
}

// ---- C1–C4：manifest 静态检查（纯函数，便于测试）----

export function checkManifest(manifest: Manifest, contract: Pick<Contract, "manifestValidate" | "registry">): Finding[] {
  const findings: Finding[] = [];

  // C1 schema 合规
  if (!contract.manifestValidate(manifest)) {
    for (const err of contract.manifestValidate.errors ?? []) {
      findings.push({ level: "error", code: "C1_manifest_schema", message: `manifest${err.instancePath} ${err.message}` });
    }
    // schema 不合规时后续按字段假设可能不成立，但仍尽量继续给出更多线索
  }

  // C3 sideload ⟹ parser（红线 #5）
  if (manifest.trustTier === "sideload" && manifest.mode !== "parser") {
    findings.push({
      level: "error",
      code: "C3_sideload_must_parser",
      message: `sideload 信任档必须为 parser 模式（无网络/无凭证），当前 mode=${manifest.mode}`,
    });
  }

  const allow = manifest.network?.allow ?? [];

  // C4-a fetch 模式须声明白名单
  if (manifest.mode === "fetch" && allow.length === 0) {
    findings.push({
      level: "error",
      code: "C4_fetch_empty_allow",
      message: "fetch 模式 network.allow 为空：无任何域名可注入凭证，adapter 取不到数",
    });
  }

  // 非 https 白名单项 → 警告
  for (const pattern of allow) {
    if (!/^https:\/\//.test(pattern)) {
      findings.push({ level: "warn", code: "C4_non_https_allow", message: `白名单项非 https：${pattern}` });
    }
  }

  for (const cap of manifest.capabilities ?? []) {
    // C2 capability ∈ registry
    const reg = contract.registry[cap.id];
    if (!reg) {
      findings.push({ level: "error", code: "C2_unregistered_capability", message: `capability '${cap.id}' 未在 registry.json 注册` });
      continue;
    }
    // C2 emits 与 registry 一致（防 schema 漂移）
    if (cap.emits?.schema !== reg.emits.schema || cap.emits?.schemaVersion !== reg.emits.schemaVersion) {
      findings.push({
        level: "error",
        code: "C2_emits_mismatch",
        message: `capability '${cap.id}' 的 emits 与 registry 不符：manifest=${cap.emits?.schema}@${cap.emits?.schemaVersion}，registry=${reg.emits.schema}@${reg.emits.schemaVersion}`,
      });
    }

    // C4-b parser 模式：每条 requests.url 须被白名单覆盖
    if (manifest.mode === "parser") {
      const requests = cap.requests ?? [];
      if (requests.length === 0) {
        findings.push({ level: "warn", code: "C4_parser_no_requests", message: `parser capability '${cap.id}' 未声明 requests：核心无从代取数据` });
      }
      for (const req of requests) {
        if (!urlCoveredByAllow(req.url, allow)) {
          findings.push({
            level: "error",
            code: "C4_request_outside_allow",
            message: `capability '${cap.id}' 的 request '${req.key}' 越出白名单：${req.url}`,
          });
        }
      }
    }
  }

  // C6–C8 凭证声明检查（ADR-013 §2.4）。credentials 可选；缺省即跳过。
  findings.push(...checkCredentials(manifest, allow));

  return findings;
}

// ---- C6–C8：credentials 声明（ADR-013 §2.4）----

/**
 * 取 uri-template 第一个 `*` 之前的字面前缀（无 `*` 则取全串）。用于最长前缀消歧。
 * **假设**：scope 是"尾随 `*` 的前缀型"（`https://domain/path/*`，与 C6 同一约定）。
 * 多段 `*` / `{+path}` 等复杂模板不在此约定内，引入时须重评 C6/C7（见文件头与 ADR-013 §2.4）。
 */
function scopePrefix(pattern: string): string {
  const star = pattern.indexOf("*");
  return star === -1 ? pattern : pattern.slice(0, star);
}

/**
 * 两个 scope 前缀是否重叠（其一是另一的字符串前缀，含相等）。
 * **注**：C7 在 `pa.length === pb.length` 守卫下调用本函数——等长 + 互为前缀 ⟺ 相等，
 * 故 C7 实质只在"前缀完全相同"时触发。等长但不相等的前缀（如 `/api/` vs `/apx/`）匹配的
 * URL 集合互斥、无注入歧义，正确地不被判错；不同长度的重叠由运行时最长前缀胜出消解。
 */
function prefixesOverlap(a: string, b: string): boolean {
  return a.startsWith(b) || b.startsWith(a);
}

export function checkCredentials(
  manifest: Pick<Manifest, "credentials" | "mode" | "capabilities">,
  allow: string[],
): Finding[] {
  const findings: Finding[] = [];
  const creds = manifest.credentials ?? {};
  const credNames = Object.keys(creds);

  // 收集所有 scope 条目（带所属凭证名），供 C6/C7 使用
  const scopes: Array<{ name: string; pattern: string }> = [];
  for (const name of credNames) {
    const decl = creds[name];
    if (!decl) continue;

    // C9（防御性，schema C1 亦拦）：type 合法
    if (decl.type !== "cookie" && decl.type !== "header") {
      findings.push({
        level: "error",
        code: "C9_bad_credential_type",
        message: `credential '${name}' 的 type 非法：${String(decl.type)}（须为 cookie | header）`,
      });
    }

    for (const pattern of decl.scope ?? []) {
      scopes.push({ name, pattern });
      // C6 scope ⊆ network.allow
      if (!urlCoveredByAllow(pattern, allow)) {
        findings.push({
          level: "error",
          code: "C6_scope_outside_allow",
          message: `credential '${name}' 的 scope 越出 network.allow：${pattern}（不能注入一个连出口都不允许的 URL）`,
        });
      }
    }
  }

  // C7 作用域消歧：不同凭证的 scope，前缀长度相同且重叠 = 歧义 → 拒绝。
  // （长度不同的重叠由运行时"最长前缀胜出"消解，非错误。）
  for (let i = 0; i < scopes.length; i++) {
    for (let j = i + 1; j < scopes.length; j++) {
      const a = scopes[i]!;
      const b = scopes[j]!;
      if (a.name === b.name) continue; // 同一凭证内部重叠无歧义
      const pa = scopePrefix(a.pattern);
      const pb = scopePrefix(b.pattern);
      if (pa.length === pb.length && prefixesOverlap(pa, pb)) {
        findings.push({
          level: "error",
          code: "C7_ambiguous_credential_scope",
          message: `credential '${a.name}' 与 '${b.name}' 的 scope 前缀等长且重叠，注入歧义：'${a.pattern}' vs '${b.pattern}'`,
        });
      }
    }
  }

  // C8 引用闭合：parser 的 requests.credential 须在 credentials 声明；声明未用 → warn。
  const referenced = new Set<string>();
  if (manifest.mode === "parser") {
    for (const cap of manifest.capabilities ?? []) {
      for (const req of cap.requests ?? []) {
        if (req.credential === undefined) continue;
        referenced.add(req.credential);
        if (!(req.credential in creds)) {
          findings.push({
            level: "error",
            code: "C8_undeclared_credential_ref",
            message: `capability '${cap.id}' 的 request '${req.key}' 引用未声明的 credential '${req.credential}'`,
          });
        }
      }
    }
    // 仅 parser 模式判定"声明未用"：fetch 模式凭证按 scope 隐式使用，不告警。
    for (const name of credNames) {
      if (!referenced.has(name)) {
        findings.push({
          level: "warn",
          code: "C8_unused_credential",
          message: `credential '${name}' 已声明但无 request 引用（parser 模式）`,
        });
      }
    }
  }

  return findings;
}

// ---- C5：夹具 expected 合 schema（不依赖沙箱）----

function checkFixtures(dir: string, manifest: Manifest, contract: Contract): Finding[] {
  const findings: Finding[] = [];
  const fixturesDir = join(dir, "fixtures");
  if (!existsSync(fixturesDir)) return findings;

  const byCapability = new Map(manifest.capabilities.map((c) => [c.id, c]));

  for (const file of readdirSync(fixturesDir)) {
    if (!file.endsWith(".json")) continue;
    const fx = readJson<{ capability?: string; expected?: unknown }>(join(fixturesDir, file));
    if (!fx.capability || fx.expected === undefined) {
      findings.push({ level: "warn", code: "C5_fixture_shape", message: `fixtures/${file} 缺 capability 或 expected，跳过` });
      continue;
    }
    const cap = byCapability.get(fx.capability);
    if (!cap) {
      findings.push({ level: "error", code: "C5_fixture_unknown_capability", message: `fixtures/${file} 引用了 manifest 未声明的 capability '${fx.capability}'` });
      continue;
    }
    const validate = contract.schemaFor(cap.emits.schema);
    if (!validate) {
      findings.push({ level: "warn", code: "C5_schema_absent", message: `schema '${cap.emits.schema}' 尚未落盘，无法校验 fixtures/${file}` });
      continue;
    }
    if (!validate(fx.expected)) {
      for (const err of validate.errors ?? []) {
        findings.push({ level: "error", code: "C5_fixture_invalid", message: `fixtures/${file} expected${err.instancePath} ${err.message}` });
      }
    }
  }
  return findings;
}

// ---- 白名单匹配 ----

/** 把 "https://h/api/*" 形态的白名单项转成锚定正则。 */
function allowToRegex(pattern: string): RegExp {
  const escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const withWildcard = escaped.replace(/\\\*/g, ".*");
  return new RegExp("^" + withWildcard + "$");
}

function urlCoveredByAllow(url: string, allow: string[]): boolean {
  // 把 {param} 占位换成中性 token，避免占位符干扰匹配
  const concrete = url.replace(/\{[^}]+\}/g, "_");
  return allow.some((p) => allowToRegex(p).test(concrete));
}

// ---- 编排 ----

function validateAdapterDir(dir: string, contract: Contract): Finding[] {
  const manifestPath = join(dir, "manifest.json");
  if (!existsSync(manifestPath)) {
    return [{ level: "error", code: "no_manifest", message: `${dir} 下无 manifest.json` }];
  }
  let manifest: Manifest;
  try {
    manifest = readJson<Manifest>(manifestPath);
  } catch (err) {
    return [{ level: "error", code: "manifest_unparseable", message: `manifest.json 解析失败：${(err as Error).message}` }];
  }
  return [...checkManifest(manifest, contract), ...checkFixtures(dir, manifest, contract)];
}

/** 递归发现 adapters/ 下含 manifest.json 的目录。 */
function discoverAdapters(root: string): string[] {
  const out: string[] = [];
  const walk = (d: string): void => {
    if (existsSync(join(d, "manifest.json"))) {
      out.push(d);
      return; // adapter 目录不再下钻
    }
    for (const entry of readdirSync(d)) {
      const p = join(d, entry);
      if (statSync(p).isDirectory()) walk(p);
    }
  };
  walk(root);
  return out;
}

function main(): void {
  const arg = process.argv.find((a) => a.startsWith("--adapter="));
  const contract = loadContract();

  const dirs = arg ? [arg.slice("--adapter=".length)] : discoverAdapters(adaptersRoot);
  if (dirs.length === 0) {
    console.log("没有发现任何 adapter。");
    return;
  }

  let errorCount = 0;
  for (const dir of dirs) {
    const findings = validateAdapterDir(dir, contract);
    const errors = findings.filter((f) => f.level === "error");
    const warns = findings.filter((f) => f.level === "warn");
    errorCount += errors.length;

    const label = basename(dir);
    if (findings.length === 0) {
      console.log(`✓ ${label}`);
    } else {
      console.log(`${errors.length ? "✗" : "•"} ${label}  (${errors.length} error, ${warns.length} warn)`);
      for (const f of findings) {
        console.log(`    ${f.level === "error" ? "✗" : "⚠"} [${f.code}] ${f.message}`);
      }
    }
  }

  if (errorCount > 0) {
    console.error(`\n校验失败：${errorCount} 个 error。`);
    process.exit(1);
  }
  console.log("\n校验通过。");
}

// 仅在被直接执行时跑 CLI；被 import（如 smoke 测试）时不触发。
const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
