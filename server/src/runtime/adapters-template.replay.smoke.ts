/** 核心仓 template 的真实 QuickJS fixture replay；防止示例代码与契约静默漂移。 */

import { join } from "node:path";
import { replayDeclarativeFixture } from "./__testutils__/declarative-replay.js";
import { replayImperativeFixture } from "./__testutils__/imperative-replay.js";
import { resolveRepoRoot, runMain } from "./__testutils__/smoke-utils.js";

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  await replayDeclarativeFixture(
    import.meta.url,
    join(repoRoot, "adapters/_template/declarative"),
    "fixtures/grades.list.json",
  );
  await replayImperativeFixture(
    import.meta.url,
    join(repoRoot, "adapters/_template/imperative"),
    "fixtures/grades.list.json",
  );
  console.log("adapter templates：declarative/imperative fixture replay 通过");
}

runMain(main);
