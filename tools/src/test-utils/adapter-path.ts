/** 解析 ADR-018 外置 adapter 源；工具链用例缺依赖时必须 fail-closed。 */

import { statSync } from "node:fs";
import { join, resolve } from "node:path";

export function requireAdapterDir(repoRoot: string, adapterId: string): string {
  const candidates = [
    ...(process.env.ELECON_ADAPTERS_REPO ? [process.env.ELECON_ADAPTERS_REPO] : []),
    join(repoRoot, "vendor/elecon-adapters"),
    resolve(repoRoot, "../elecon-adapters"),
  ];
  for (const root of candidates) {
    const dir = join(root, "adapters", adapterId);
    try {
      if (statSync(join(dir, "index.js")).isFile()) return dir;
    } catch {
      /* 下一个候选 */
    }
  }
  throw new Error(
    `缺必需 adapter '${adapterId}'：请检出 vendor/elecon-adapters submodule 或设置 ELECON_ADAPTERS_REPO`,
  );
}
