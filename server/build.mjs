import { readdirSync, rmSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const dist = join(root, "dist");
rmSync(dist, { recursive: true, force: true });

const tsc = join(root, "../node_modules/typescript/bin/tsc");
const result = spawnSync(process.execPath, [tsc, "-p", "tsconfig.build.json"], {
  cwd: root,
  stdio: "inherit",
});
if (result.status !== 0) process.exit(result.status ?? 1);

const files = [];
const walk = (dir) => {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) walk(path);
    else files.push(path.slice(dist.length + 1));
  }
};
walk(dist);

const forbidden = files.filter((path) => path.includes(".smoke.") || path.includes("__testutils__"));
if (forbidden.length > 0) {
  throw new Error(`production build 包含测试文件：${forbidden.join(", ")}`);
}
for (const required of ["public/index.js", "runtime/sandbox.js"]) {
  if (!files.includes(required)) throw new Error(`production build 缺少入口：${required}`);
}
console.log(`server production build：${files.length} 个文件，零 smoke/testutils`);
