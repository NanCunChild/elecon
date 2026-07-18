/** 通用 parser fixture 回放 smoke：验证不同 adapter 共用同一回放路径。 */

import { replayParserFixture } from "./__testutils__/parser-replay.js";
import { resolveRepoRoot, runMain } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  await replayParserFixture(
    import.meta.url,
    `${repoRoot}adapters/_template/parser`,
    "fixtures/grades.list.json",
  );
  console.log("  ✓ template parser fixture：golden + schema");

  await replayParserFixture(
    import.meta.url,
    `${repoRoot}adapters/school-xidian`,
    "fixtures/notice.list.json",
  );
  console.log("  ✓ school-xidian parser fixture：golden + schema");

  console.log("parser replay smoke 全部通过 ✅");
}

runMain(main);
