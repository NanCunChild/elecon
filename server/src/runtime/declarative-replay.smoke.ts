/** 通用 declarative fixture 回放 smoke：验证不同 adapter 共用同一回放路径（ADR-022）。 */

import { replayDeclarativeFixture } from "./__testutils__/declarative-replay.js";
import { adapterDirIfPresent, resolveRepoRoot, runMain, skipSmoke } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  await replayDeclarativeFixture(
    import.meta.url,
    `${repoRoot}adapters/_template/declarative`,
    "fixtures/grades.list.json",
  );
  console.log("  ✓ template declarative fixture：golden + schema");

  const xidianDir = adapterDirIfPresent(repoRoot, "school-xidian");
  if (!xidianDir) {
    skipSmoke("缺 elecon-adapters 中的 school-xidian declarative fixture");
    return;
  }
  await replayDeclarativeFixture(import.meta.url, xidianDir, "fixtures/notice.list.json");
  console.log("  ✓ school-xidian declarative fixture：golden + schema");

  console.log("declarative replay smoke 全部通过 ✅");
}

runMain(main);
