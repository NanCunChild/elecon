/**
 * catalog 校验器（ADR-018 §2.5）—— **核心分发侧**,校验签名前的 catalog 载荷。
 *
 * 检查项：
 *  K0 catalog 对 `contract/catalog.schema.json` 的合规性（ajv）
 *  K1 每 entry.capabilities 须 ∈ registry.json ——**catalog 不得引入新 capability id**
 *     （热推只在既有能力集内换数据源映射,守 ADR-010 §3.3.2(a) 立论）
 *  K2 同一 adapterId 多条目 → warn（加载器需明确取哪条）
 *
 * **不在此**（属运行时 / 🔒 Phase 2 客户端加载器）：catalog **签名验签**、`sequence` 防回滚、
 *   TTL/last-good、digest 与实际 bundle 字节比对。本静态校验只保证"载荷合法 + 不越能力集"。
 *
 *   运行：cd tools && npx tsx src/catalog/validate.ts --catalog=<path>
 */

import { readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020, type ValidateFunction } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const contractDir = join(repoRoot, "contract");

export type Level = "error" | "warn";
export interface Finding {
  level: Level;
  code: string;
  message: string;
}

export interface CatalogEntry {
  adapterId: string;
  adapterVersion: string;
  digest: string;
  url: string;
  stdlibMin?: string;
  capabilities: string[];
}

export interface Catalog {
  catalogVersion: string;
  sequence: number;
  issuedAt: string;
  ttlSeconds: number;
  entries: CatalogEntry[];
}

export function loadCatalogValidator(): ValidateFunction {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const schema = JSON.parse(readFileSync(join(contractDir, "catalog.schema.json"), "utf8")) as Record<
    string,
    unknown
  >;
  return ajv.compile(schema);
}

export function loadRegistryIds(): Set<string> {
  const reg = JSON.parse(readFileSync(join(contractDir, "capability", "registry.json"), "utf8")) as {
    capabilities: Record<string, unknown>;
  };
  return new Set(Object.keys(reg.capabilities));
}

/** 纯校验：schema + capability ⊆ registry + 重复条目。便于单测直接调用。 */
export function checkCatalog(
  catalog: Catalog,
  deps: { catalogValidate: ValidateFunction; registryIds: Set<string> },
): Finding[] {
  const findings: Finding[] = [];

  // K0 schema 合规
  if (!deps.catalogValidate(catalog)) {
    for (const err of deps.catalogValidate.errors ?? []) {
      findings.push({
        level: "error",
        code: "K0_catalog_schema",
        message: `catalog${err.instancePath} ${err.message}`,
      });
    }
  }

  const seen = new Map<string, string>(); // adapterId → 首见 version
  for (const [i, e] of (catalog.entries ?? []).entries()) {
    // K1 capabilities ⊆ registry（不得引入新能力）
    for (const cap of e.capabilities ?? []) {
      if (!deps.registryIds.has(cap)) {
        findings.push({
          level: "error",
          code: "K1_unregistered_capability",
          message: `entries[${i}] (${e.adapterId}) capability '${cap}' 不在 registry：catalog 不得引入新能力（ADR-010 §2.1）`,
        });
      }
    }
    // K2 同 adapterId 多条目 → warn
    const prev = seen.get(e.adapterId);
    if (prev !== undefined) {
      findings.push({
        level: "warn",
        code: "K2_duplicate_adapter",
        message: `adapterId '${e.adapterId}' 多条目（${prev} 与 ${e.adapterVersion}）：加载器需明确取哪条`,
      });
    }
    seen.set(e.adapterId, e.adapterVersion);
  }

  return findings;
}

function main(): void {
  const arg = process.argv.find((a) => a.startsWith("--catalog="));
  if (!arg) {
    console.error("用法：--catalog=<path>");
    process.exit(2);
  }
  const catalog = JSON.parse(readFileSync(arg.slice("--catalog=".length), "utf8")) as Catalog;
  const findings = checkCatalog(catalog, {
    catalogValidate: loadCatalogValidator(),
    registryIds: loadRegistryIds(),
  });
  const errors = findings.filter((f) => f.level === "error");
  for (const f of findings) {
    console.log(`${f.level === "error" ? "✗" : "⚠"} [${f.code}] ${f.message}`);
  }
  if (errors.length > 0) {
    console.error(`\ncatalog 校验失败：${errors.length} error。`);
    process.exit(1);
  }
  console.log("catalog 校验通过。");
}

const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
