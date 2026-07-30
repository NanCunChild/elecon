/** school-fudan notice.list declarative fixture smoke（ADR-022）。 */
import { replayDeclarativeFixture } from "./__testutils__/declarative-replay.js";
import { adapterDirIfPresent, resolveRepoRoot, runMain, skipSmoke } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  const adapterDir = adapterDirIfPresent(repoRoot, "school-fudan");
  if (!adapterDir) {
    skipSmoke(
      "缺 elecon-adapters 兄弟仓（CI 未检出）；本 smoke 依赖公开 adapter 源。见 ADR-018 / mirror-adapters。",
    );
    return;
  }
  await replayDeclarativeFixture(import.meta.url, adapterDir, "fixtures/notice.list.json");
  console.log("school-fudan notice.list：declarative fixture + schema + golden 通过");
}

runMain(main);
