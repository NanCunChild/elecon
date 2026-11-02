/** V1 退役模板的真实 QuickJS fixture replay；保留旧执行器的契约回归。 */

import { join } from "node:path";
import { replayDeclarativeFixture } from "./__testutils__/declarative-replay.js";
import { replayImperativeFixture } from "./__testutils__/imperative-replay.js";
import { resolveRepoRoot, runMain } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  await replayDeclarativeFixture(
    import.meta.url,
    join(repoRoot, "tests/fixtures/legacy-adapters/declarative"),
    "fixtures/grades.list.json",
  );
  await replayImperativeFixture(
    import.meta.url,
    join(repoRoot, "tests/fixtures/legacy-adapters/imperative"),
    "fixtures/grades.list.json",
  );
  console.log("legacy adapter fixtures：declarative/imperative fixture replay 通过");
}

runMain(main);
