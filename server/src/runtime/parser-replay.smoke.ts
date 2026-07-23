/** 通用 declarative fixture 回放 smoke：验证不同 adapter 共用同一回放路径（ADR-022）。 */

import { replayParserFixture } from "./__testutils__/parser-replay.js";
import { resolveRepoRoot, runMain } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  await replayParserFixture(
    import.meta.url,
    `${repoRoot}adapters/_template/declarative`,
    "fixtures/grades.list.json",
  );
  console.log("  ✓ template declarative fixture：golden + schema");

  await replayParserFixture(
    import.meta.url,
    `${repoRoot}adapters/school-xidian`,
    "fixtures/notice.list.json",
  );
  console.log("  ✓ school-xidian declarative fixture：golden + schema");

  console.log("declarative replay smoke 全部通过 ✅");
}

runMain(main);
