/** 通用 fetch fixture 回放 smoke：验证多步握手和 contract schema。 */

import { resolveRepoRoot, runMain } from "./__testutils__/smoke-utils.js";
import { replayFetchFixture } from "./__testutils__/fetch-replay.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  await replayFetchFixture(import.meta.url, `${repoRoot}adapters/school-xjt`, "fixtures/fetch.replay.json");
  console.log("fetch replay smoke 全部通过 ✅");
}

runMain(main);
