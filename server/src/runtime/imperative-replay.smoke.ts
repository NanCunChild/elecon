/** 通用 imperative fixture 回放 smoke：验证多步握手和 contract schema。 */

import { replayImperativeFixture } from "./__testutils__/imperative-replay.js";
import { resolveRepoRoot, runMain } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  await replayImperativeFixture(
    import.meta.url,
    `${repoRoot}adapters/school-xjt`,
    "fixtures/imperative.replay.json",
  );
  console.log("imperative replay smoke 全部通过 ✅");
}

runMain(main);
