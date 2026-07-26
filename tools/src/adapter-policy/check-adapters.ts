#!/usr/bin/env node

/** 核心拥有的公开 adapter 编译/策略入口（ADR-018 §2.8/§2.10）。 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { build } from "esbuild";
import { type AdapterPolicyManifest, checkAdapterSourcePolicy } from "./index.js";

const root = resolve(process.env.ELECON_ADAPTERS_ROOT ?? "adapters");

for (const adapterId of readdirSync(root)) {
  const dir = join(root, adapterId);
  if (!statSync(dir).isDirectory()) continue;
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8")) as AdapterPolicyManifest & {
    runtime?: { entry?: string };
  };
  const entry = manifest.runtime?.entry ?? "index.js";
  const source = readFileSync(join(dir, entry), "utf8");

  checkAdapterSourcePolicy(adapterId, source, manifest);
  await build({
    stdin: { contents: source, sourcefile: `${adapterId}/${entry}` },
    bundle: true,
    write: false,
    format: "esm",
    platform: "neutral",
    external: ["elecon:html"],
    logLevel: "silent",
  });
  console.log(`✓ ${adapterId}: compile/import/policy`);
}
