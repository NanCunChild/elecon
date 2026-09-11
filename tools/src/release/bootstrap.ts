/**
 * 🔒 客户端 bootstrap 基线资产（ADR-010 / ADR-018 §2.6）与 endpoint-D dist 树的互转。
 *
 * **git 里只跟踪 bootstrap**（`client/assets/bootstrap/`，2026-09-11 决策）：签名仪式产出的 dist 树
 * 不入库，仪式后立即 `sync` 成 bootstrap 提交；上传端点 D 时再从 bootstrap `export` 回 dist 树。
 * 两个方向都是**纯字节搬运**（无签名、无信任裁定；客户端 loader 仍对 bootstrap 重跑验签 + 各门）：
 *
 *   sync   （dist → assets）  catalog.json = gunzip(catalog.json.gz)；revocation.json 复制；
 *                             bundles/<digest>.json.gz → bundles/<digest>.bundle（仅换扩展名）
 *   export （assets → dist）  逆向；catalog.json.gz 的 gzip 字节不必与仪式产物逐字节相同——
 *                             gzip 不在签名范围内，被签的是内层 catalogJson，逐字节不变
 *   verify （assets 自洽）    CI 门：catalog 可解析、每个 entry.digest 都有对应 bundle、无游离 bundle、
 *                             每个 bundle 的文件名 == inspectBundle 重算出的 envelope digest
 *   check  （assets vs dist） 仅当本地有 dist 树时可用（仪式当天核对）
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";
import { inspectBundle } from "../bundle/package.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

/** 内容寻址 digest 形态 = 64 位小写 hex（对齐客户端 bootstrap.dart 的 `_reDigest`，防路径穿越/畸形）。 */
const DIGEST_RE = /^[0-9a-f]{64}$/;
const BUNDLE_SUFFIX = ".json.gz";

export interface SyncBootstrapOptions {
  distDir: string;
  assetsDir: string;
  /** true = 只比对、不写盘；返回漂移文件列表供 CI 判定。 */
  check?: boolean;
}

export interface SyncBootstrapResult {
  /** 写盘模式下已派生的资产相对路径（check 模式为空）。 */
  written: string[];
  /** 与 dist 不一致的资产相对路径（仅 check 模式填充）。 */
  drift: string[];
}

interface DerivedFile {
  rel: string;
  bytes: Buffer;
}

/** 计算 bootstrap 资产的派生计划（rel 路径 + 期望字节）；不触盘。 */
function planDerivation(distDir: string): DerivedFile[] {
  const plan: DerivedFile[] = [
    // catalog 以 gzip 传输，bootstrap 侧存明文签名信封。
    { rel: "catalog.json", bytes: gunzipSync(readFileSync(join(distDir, "catalog.json.gz"))) },
    { rel: "revocation.json", bytes: readFileSync(join(distDir, "revocation.json")) },
  ];
  const bundlesDir = join(distDir, "bundles");
  for (const name of readdirSync(bundlesDir).sort()) {
    if (!name.endsWith(BUNDLE_SUFFIX)) continue;
    const digest = name.slice(0, -BUNDLE_SUFFIX.length);
    if (!DIGEST_RE.test(digest)) {
      throw new Error(`dist bundle 文件名非内容寻址 digest（fail-closed）：${name}`);
    }
    plan.push({
      rel: join("bundles", `${digest}.bundle`),
      bytes: readFileSync(join(bundlesDir, name)),
    });
  }
  return plan;
}

/**
 * 从 [distDir] 派生 bootstrap 资产到 [assetsDir]。写盘模式覆盖写；check 模式只比对，返回漂移列表。
 */
export function syncBootstrap(options: SyncBootstrapOptions): SyncBootstrapResult {
  const distDir = resolve(options.distDir);
  const assetsDir = resolve(options.assetsDir);
  const check = options.check ?? false;

  const plan = planDerivation(distDir);
  const written: string[] = [];
  const drift: string[] = [];
  for (const item of plan) {
    const dest = join(assetsDir, item.rel);
    if (check) {
      const current = existsSync(dest) ? readFileSync(dest) : null;
      if (current === null || !current.equals(item.bytes)) drift.push(item.rel);
    } else {
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, item.bytes);
      written.push(item.rel);
    }
  }
  return { written, drift };
}

const BOOTSTRAP_BUNDLE_SUFFIX = ".bundle";

/**
 * bootstrap 资产自洽校验（CI 门；不验签、不裁定信任）。返回问题列表，空 = 通过。
 * 只证「入库的这棵树内部一致」：catalog 指到的每个 digest 都在、没有多余字节随 app 发布、
 * 每个 bundle 文件名就是其 envelope 的真实 digest（inspectBundle 重算，keyless）。
 */
export function verifyBootstrapAssets(assetsDir: string): string[] {
  const dir = resolve(assetsDir);
  const problems: string[] = [];
  const catalogPath = join(dir, "catalog.json");
  const revocationPath = join(dir, "revocation.json");
  if (!existsSync(catalogPath)) return [`缺 catalog.json：${catalogPath}`];
  if (!existsSync(revocationPath)) problems.push(`缺 revocation.json：${revocationPath}`);

  let digests: string[] = [];
  try {
    const outer = JSON.parse(readFileSync(catalogPath, "utf8")) as { catalogJson?: unknown };
    if (typeof outer.catalogJson !== "string") throw new Error("缺 catalogJson 字段");
    const catalog = JSON.parse(outer.catalogJson) as { entries?: Array<{ digest?: unknown }> };
    digests = (catalog.entries ?? []).map((e) => {
      if (typeof e.digest !== "string" || !DIGEST_RE.test(e.digest))
        throw new Error(`entry.digest 非法：${String(e.digest)}`);
      return e.digest;
    });
  } catch (error: unknown) {
    problems.push(`catalog.json 不可解析：${error instanceof Error ? error.message : String(error)}`);
    return problems;
  }
  if (existsSync(revocationPath)) {
    try {
      const outer = JSON.parse(readFileSync(revocationPath, "utf8")) as { listJson?: unknown };
      if (typeof outer.listJson !== "string") throw new Error("缺 listJson 字段");
    } catch (error: unknown) {
      problems.push(`revocation.json 不可解析：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  const bundlesDir = join(dir, "bundles");
  const present = new Set<string>();
  for (const name of existsSync(bundlesDir) ? readdirSync(bundlesDir).sort() : []) {
    if (!name.endsWith(BOOTSTRAP_BUNDLE_SUFFIX)) {
      problems.push(`bundles/ 含非 .bundle 文件：${name}`);
      continue;
    }
    const digest = name.slice(0, -BOOTSTRAP_BUNDLE_SUFFIX.length);
    if (!DIGEST_RE.test(digest)) {
      problems.push(`bundle 文件名非 digest：${name}`);
      continue;
    }
    present.add(digest);
    const inspected = inspectBundle(readFileSync(join(bundlesDir, name)));
    if (!inspected.ok) {
      problems.push(`bundle ${name} 自检失败：${inspected.reason}`);
    } else if (inspected.value !== digest) {
      problems.push(`bundle ${name} 文件名与 envelope digest 不符（实为 ${inspected.value}）`);
    }
  }
  for (const d of digests) {
    if (!present.has(d)) problems.push(`catalog entry 指向的 bundle 缺失：bundles/${d}.bundle`);
  }
  const referenced = new Set(digests);
  for (const d of present) {
    if (!referenced.has(d))
      problems.push(`游离 bundle（catalog 未引用，却会随 app 发布）：bundles/${d}.bundle`);
  }
  return problems;
}

/**
 * 从 bootstrap 资产反向导出 endpoint-D dist 树（上传用）。先过 [verifyBootstrapAssets]，不自洽即拒。
 * 返回写出的相对路径。
 */
export function exportDist(options: { assetsDir: string; distDir: string }): string[] {
  const assetsDir = resolve(options.assetsDir);
  const distDir = resolve(options.distDir);
  const problems = verifyBootstrapAssets(assetsDir);
  if (problems.length > 0) {
    throw new Error(`bootstrap 资产不自洽，拒绝导出：\n  ${problems.join("\n  ")}`);
  }
  const written: string[] = [];
  const put = (rel: string, bytes: Buffer): void => {
    const dest = join(distDir, rel);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, bytes);
    written.push(rel);
  };
  put("catalog.json.gz", gzipSync(readFileSync(join(assetsDir, "catalog.json"))));
  put("revocation.json", readFileSync(join(assetsDir, "revocation.json")));
  for (const name of readdirSync(join(assetsDir, "bundles")).sort()) {
    const digest = name.slice(0, -BOOTSTRAP_BUNDLE_SUFFIX.length);
    put(join("bundles", `${digest}${BUNDLE_SUFFIX}`), readFileSync(join(assetsDir, "bundles", name)));
  }
  return written;
}

function arg(name: string): string | undefined {
  return process.argv.find((value) => value.startsWith(`--${name}=`))?.slice(name.length + 3);
}

function main(): void {
  const assetsDir = arg("assets") ?? join(repoRoot, "client/assets/bootstrap");
  const verify = process.argv.includes("--verify");
  const exportTo = arg("export-dist");
  try {
    if (verify) {
      const problems = verifyBootstrapAssets(assetsDir);
      if (problems.length > 0) {
        console.error(`bootstrap 资产不自洽：\n  ${problems.join("\n  ")}`);
        process.exitCode = 1;
      } else {
        console.log("bootstrap 资产自洽（catalog ↔ bundles ↔ envelope digest 一致）");
      }
      return;
    }
    if (exportTo !== undefined) {
      const written = exportDist({ assetsDir, distDir: exportTo });
      console.log(`dist 树已从 bootstrap 导出（${written.length} 个文件）：${resolve(exportTo)}`);
      return;
    }
    const distDir = arg("dist") ?? join(repoRoot, "dist-full");
    const check = process.argv.includes("--check");
    const result = syncBootstrap({ distDir, assetsDir, check });
    if (check) {
      if (result.drift.length > 0) {
        console.error(
          `bootstrap 资产与 dist 漂移（运行 \`npm run bootstrap:sync\` 重新派生）：\n  ${result.drift.join("\n  ")}`,
        );
        process.exitCode = 1;
      } else {
        console.log("bootstrap 资产与 dist 一致");
      }
    } else {
      console.log(`bootstrap 资产已从 dist 派生（${result.written.length} 个文件）：${assetsDir}`);
    }
  } catch (error: unknown) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}

const invokedDirectly =
  process.argv[1] !== undefined && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);

if (invokedDirectly) main();
