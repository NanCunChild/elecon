/** pinned adapters 全量 fixture replay 门：真实 QuickJS handler -> expected -> contract schema。 */

import { strict as assert } from "node:assert";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { replayDeclarativeFixture } from "./__testutils__/declarative-replay.js";
import { replayImperativeFixture } from "./__testutils__/imperative-replay.js";
import { adaptersRepoRoot, resolveRepoRoot, runMain, skipSmoke } from "./__testutils__/smoke-utils.js";

interface FixtureShape {
  kind?: string;
  capability?: string;
  expected?: unknown;
  responses?: unknown;
}

interface ManifestShape {
  capabilities: Array<{ id: string; requestGraph: "declarative" | "imperative" }>;
}

const repoRoot = resolveRepoRoot(import.meta.url);

async function main(): Promise<void> {
  const adaptersRoot = join(adaptersRepoRoot(repoRoot), "adapters");
  try {
    assert.ok(statSync(adaptersRoot).isDirectory());
  } catch {
    if (process.env.ELECON_REQUIRE_ADAPTERS === "1") throw new Error(`缺 pinned adapters：${adaptersRoot}`);
    skipSmoke(`缺 pinned adapters：${adaptersRoot}`);
    return;
  }

  let replayed = 0;
  for (const entry of readdirSync(adaptersRoot, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.startsWith("school-")) continue;
    const adapterDir = join(adaptersRoot, entry.name);
    const fixturesDir = join(adapterDir, "fixtures");
    try {
      if (!statSync(fixturesDir).isDirectory()) continue;
    } catch {
      continue;
    }

    const manifest = JSON.parse(readFileSync(join(adapterDir, "manifest.json"), "utf8")) as ManifestShape;
    const requestGraph = new Map(
      manifest.capabilities.map((capability) => [capability.id, capability.requestGraph]),
    );
    for (const fixtureFile of readdirSync(fixturesDir)
      .filter((file) => file.endsWith(".json"))
      .sort()) {
      const fixtureName = `fixtures/${fixtureFile}`;
      const fixture = JSON.parse(readFileSync(join(adapterDir, fixtureName), "utf8")) as FixtureShape;
      assert.ok(fixture.capability, `${entry.name}/${fixtureName} 缺 capability`);
      assert.notEqual(fixture.expected, undefined, `${entry.name}/${fixtureName} 缺 expected`);
      assert.notEqual(fixture.responses, undefined, `${entry.name}/${fixtureName} 缺 responses`);
      const graph = requestGraph.get(fixture.capability!);
      assert.ok(graph, `${entry.name}/${fixtureName} capability 未在 manifest 声明`);

      if (graph === "imperative") {
        assert.equal(fixture.kind, "imperative-replay", `${entry.name}/${fixtureName} kind 不正确`);
        await replayImperativeFixture(import.meta.url, adapterDir, fixtureName);
      } else {
        await replayDeclarativeFixture(import.meta.url, adapterDir, fixtureName);
      }
      replayed += 1;
    }
  }

  assert.ok(replayed > 0, "pinned adapters 没有可回放 fixture");
  console.log(`pinned adapter fixture replay：${replayed} 项全部通过`);
}

runMain(main);
