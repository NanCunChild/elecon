#!/usr/bin/env node

/**
 * smoke 目录发现 runner —— 消灭手工维护的 `smoke:all` && 链。
 *
 * 动机（审阅发现）：手工链有两处已兑现的风险——tools 的 scanner/codegen/signer
 * smoke 写了却从未进 CI；新增 smoke 文件依赖"记得补链"。本脚本按约定
 * `src/**\/*.smoke.ts` 递归发现并逐个执行，新文件不可能被漏跑。
 *
 * 约定：
 *  - 从**包目录**（server/ 或 tools/）以 `node ../scripts/run-smokes.mjs [dir]` 调用，
 *    dir 缺省 `src`；用包本地的 node_modules/.bin/tsx 执行（POSIX；本项目 dev/CI 均 Linux）。
 *  - 全部跑完再汇总（不 fail-fast），任一失败 exit 1——CI 一次给出全量信号。
 *  - 顺序：路径字典序，确定性输出。
 */

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";

const root = process.cwd();
const scanDir = join(root, process.argv[2] ?? "src");

// tsx 二进制：从包目录向上找（npm workspace 提升后依赖在仓库根 node_modules）。
function findTsx(from) {
  let dir = from;
  for (let i = 0; i < 5; i++) {
    const candidate = join(dir, "node_modules", ".bin", "tsx");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

const tsx = findTsx(root);
if (tsx === null) {
  console.error("run-smokes: 找不到 node_modules/.bin/tsx（先在仓库根 npm ci）");
  process.exit(1);
}

function discover(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules") continue;
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) out.push(...discover(p));
    else if (entry.endsWith(".smoke.ts")) out.push(p);
  }
  return out.sort();
}

const files = discover(scanDir);
if (files.length === 0) {
  console.error(`run-smokes: ${scanDir} 下未发现 *.smoke.ts`);
  process.exit(1);
}

const failures = [];
for (const file of files) {
  const rel = relative(root, file);
  console.log(`\n━━ smoke: ${rel} ━━`);
  const r = spawnSync(tsx, [file], { stdio: "inherit" });
  if (r.status !== 0) failures.push(rel);
}

console.log(`\nrun-smokes: ${files.length - failures.length}/${files.length} 通过`);
if (failures.length > 0) {
  console.error(`失败：\n  ${failures.join("\n  ")}`);
  process.exit(1);
}
