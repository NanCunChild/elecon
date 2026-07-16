/**
 * catalog 校验器冒烟测试（ADR-018 §2.5）—— 针对 checkCatalog 的纯逻辑断言。
 * 用真实 `contract/catalog.schema.json` + registry.json 编译。
 *
 *   运行：cd tools && npx tsx src/catalog/catalog.smoke.ts
 */

import { strict as assert } from "node:assert";
import { type Catalog, checkCatalog, loadCatalogValidator, loadRegistryIds } from "./validate.js";

const catalogValidate = loadCatalogValidator();
const registryIds = loadRegistryIds();
const deps = { catalogValidate, registryIds };

function codes(f: { code: string }[]): string[] {
  return f.map((x) => x.code);
}

const DIGEST = "a".repeat(64); // 合法 64-hex 占位

function baseEntry(over: Partial<Catalog["entries"][number]> = {}): Catalog["entries"][number] {
  return {
    adapterId: "school-xidian",
    adapterVersion: "0.1.0",
    digest: DIGEST,
    url: "https://cdn.example.org/adapters/school-xidian/0.1.0.json.gz",
    capabilities: ["notice.list"],
    ...over,
  };
}

function base(entries: Catalog["entries"]): Catalog {
  return {
    catalogVersion: "1.0",
    sequence: 7,
    issuedAt: "2026-07-15T00:00:00Z",
    ttlSeconds: 3600,
    entries,
  };
}

// 1) 合法 catalog → 无 error
{
  const f = checkCatalog(base([baseEntry()]), deps);
  assert.equal(
    f.filter((x) => x.level === "error").length,
    0,
    `合法 catalog 不应有 error：${JSON.stringify(f)}`,
  );
  console.log("  ✓ 合法 catalog 通过");
}

// 2) 未注册 capability → K1（catalog 不得引入新能力）
{
  const f = checkCatalog(base([baseEntry({ capabilities: ["ghost.cap"] })]), deps);
  assert.ok(codes(f).includes("K1_unregistered_capability"), "未注册 capability 应触发 K1");
  console.log("  ✓ 未注册 capability 被拒（K1）");
}

// 3) 非法 digest（非 64-hex）→ K0 schema
{
  const f = checkCatalog(base([baseEntry({ digest: "xyz" })]), deps);
  assert.ok(codes(f).includes("K0_catalog_schema"), "非法 digest 应触发 K0 schema");
  console.log("  ✓ 非法 digest 被 schema 拒（K0）");
}

// 4) 缺 required 字段（无 sequence）→ K0
{
  const bad = { ...base([baseEntry()]) } as Partial<Catalog>;
  delete bad.sequence;
  const f = checkCatalog(bad as Catalog, deps);
  assert.ok(codes(f).includes("K0_catalog_schema"), "缺 sequence 应触发 K0");
  console.log("  ✓ 缺 required 字段被拒（K0）");
}

// 5) 同 adapterId 多条目 → K2 warn（非 error）
{
  const f = checkCatalog(
    base([baseEntry({ adapterVersion: "0.1.0" }), baseEntry({ adapterVersion: "0.2.0" })]),
    deps,
  );
  assert.ok(codes(f).includes("K2_duplicate_adapter"), "重复 adapterId 应触发 K2");
  assert.equal(f.filter((x) => x.level === "error").length, 0, "重复条目应为 warn 而非 error");
  console.log("  ✓ 重复 adapterId 仅告警（K2 warn）");
}

// 6) 额外字段（additionalProperties: false）→ K0
{
  const f = checkCatalog(base([baseEntry({ evil: 1 } as never)]), deps);
  assert.ok(codes(f).includes("K0_catalog_schema"), "entry 额外字段应触发 K0");
  console.log("  ✓ entry 额外字段被拒（K0）");
}

// 7) signCatalog → verifyCatalog 往返 + 篡改拒（dev backend）
{
  const { generateKeyPairSync } = await import("node:crypto");
  const { LocalDevSignBackend } = await import("../signer/index.js");
  const { signCatalog, verifyCatalog } = await import("./sign.js");
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const backend = new LocalDevSignBackend(privateKey, "dev-local");

  const catalog = base([baseEntry()]);
  const signed = await signCatalog(catalog, backend);
  const good = verifyCatalog(signed, publicKey);
  assert.equal(good.ok, true, "signCatalog 产物应验过");
  assert.deepEqual(good.ok && good.value, catalog, "验签应返回已解析 catalog");

  // 篡改 sequence（防回滚要点）→ 字节变了 → 验签失败
  const tampered = {
    ...signed,
    catalogJson: JSON.stringify({ ...catalog, sequence: catalog.sequence + 1 }),
  };
  assert.equal(verifyCatalog(tampered, publicKey).ok, false, "篡改 catalog 应验签失败");

  const { publicKey: other } = generateKeyPairSync("ed25519");
  assert.equal(verifyCatalog(signed, other).ok, false, "错公钥应验签失败");

  // 字节精确：签名覆盖**整份 JSON 字节**——新增/未知字段也在签名范围内，改它必然验签失败
  // （这正是弃用手写 serialize() 的目的：不会有字段"静默落在签名范围外"）
  const withExtra = {
    ...signed,
    catalogJson: JSON.stringify({ ...catalog, futureField: "injected" }),
  };
  assert.equal(verifyCatalog(withExtra, publicKey).ok, false, "注入任意新字段应验签失败（签名覆盖全字节）");
  console.log("  ✓ signCatalog → verifyCatalog 往返 + 篡改/错公钥/注入新字段拒（字节精确）");
}

console.log("\ncatalog smoke 全部通过 ✅");
