/**
 * 🔒 从已签名的 endpoint-D dist 树派生客户端 bootstrap 基线资产（ADR-010 / ADR-018 §2.6）。
 *
 * dist（`release/package.ts` 的产物）是**单一真值源**：bootstrap 资产是它的纯字节派生。本命令取代
 * 「dist 与 client/assets/bootstrap 两处手工复制」，消除易漂移的孪生副本（评审：重复逻辑）。
 *
 * 派生规则（**无签名、无信任裁定，仅搬字节**——bootstrap 与线上产物同格式，客户端 loader 仍对其
 * 重跑验签 + 各门后才采用）：
 *   catalog.json        = gunzip(dist/catalog.json.gz)     —— app 内以明文 SignedCatalog 读取
 *   revocation.json     = 复制 dist/revocation.json
 *   bundles/<digest>.bundle = 复制 dist/bundles/<digest>.json.gz（内容寻址文件名，仅换扩展名）
 *
 * `--check` 只校验不写：任一派生文件与 dist 不一致即非零退出（CI 防漂移守卫）。本命令不签名、不改动
 * dist。
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";

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

function arg(name: string): string | undefined {
  return process.argv.find((value) => value.startsWith(`--${name}=`))?.slice(name.length + 3);
}

function main(): void {
  const distDir = arg("dist") ?? join(repoRoot, "dist-helloworld");
  const assetsDir = arg("assets") ?? join(repoRoot, "client/assets/bootstrap");
  const check = process.argv.includes("--check");
  try {
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
