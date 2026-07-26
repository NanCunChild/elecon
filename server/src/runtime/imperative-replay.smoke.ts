/** 通用 imperative fixture 回放 smoke：验证多步握手和 contract schema。 */

import { replayImperativeFixture } from "./__testutils__/imperative-replay.js";
import { adapterDirIfPresent, resolveRepoRoot, runMain, skipSmoke } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  const xjtDir = adapterDirIfPresent(repoRoot, "school-xjt");
  if (!xjtDir) {
    skipSmoke("缺 elecon-adapters 中的 school-xjt imperative fixture");
    return;
  }
  await replayImperativeFixture(import.meta.url, xjtDir, "fixtures/imperative.replay.json");
  console.log("imperative replay smoke 全部通过 ✅");
}

runMain(main);
