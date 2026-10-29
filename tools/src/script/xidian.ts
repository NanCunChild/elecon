/** ADR-034/035: build the independently installable Xidian SDK 2 packages. */
import { randomBytes } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { packageScript } from "./package.js";

const root = fileURLToPath(new URL("../../../school-scripts/xidian/", import.meta.url));
const banner = `/*! Copyright 2023-2025 BenderBlog Rodriguez and contributors.
 * Copyright 2025 Traintime PDA authors. Copyright 2026 elecon contributors.
 * SPDX-License-Identifier: MPL-2.0
 * Protocol adaptation sources: school-scripts/xidian/src/; license and source
 * provenance: school-scripts/xidian/LICENSE and README.md in the elecon repository.
 */`;

/** Compile only; esbuild and packageScript never evaluate the school module. */
export async function buildXidianPackages(): Promise<Map<string, string>> {
  const packages = new Map<string, string>();
  for (const [entry, manifestFile, name] of [
    ["index.js", "manifest.json", "school-xidian.elecon.json"],
    ["login.js", "login.manifest.json", "school-xidian-login.elecon.json"],
  ]) {
    const manifest = JSON.parse(await readFile(join(root, manifestFile!), "utf8"));
    const result = await build({
      absWorkingDir: root,
      entryPoints: [join(root, "src", entry!)],
      bundle: true,
      write: false,
      format: "esm",
      platform: "neutral",
      target: "es2020",
      external: ["elecon:html"],
      legalComments: "inline",
      banner: { js: banner },
      logLevel: "silent",
      charset: "utf8",
    });
    const source = result.outputFiles[0]?.text;
    packages.set(name!, packageScript(manifest, source));
  }
  return packages;
}

export async function writeXidianPackages(outputDirectory: string): Promise<void> {
  // Validate both packages before replacing either output.
  const packages = await buildXidianPackages();
  await mkdir(outputDirectory, { recursive: true });
  for (const [name, source] of packages) {
    const output = join(outputDirectory, name);
    const temporary = join(dirname(output), `.xidian-${randomBytes(12).toString("hex")}.tmp`);
    try {
      await writeFile(temporary, source, { flag: "wx", mode: 0o600 });
      await rename(temporary, output);
    } finally {
      await rm(temporary, { force: true });
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length !== 0 && (args.length !== 2 || args[0] !== "--out-dir" || !args[1])) {
      throw new Error("usage");
    }
    const caller =
      process.env.npm_lifecycle_event === "scripts:xidian" && process.env.INIT_CWD
        ? process.env.INIT_CWD
        : process.cwd();
    await writeXidianPackages(args[1] ? resolve(caller, args[1]) : join(root, "dist"));
    console.log("xidian_packages_created");
  } catch {
    console.error("xidian_package_build_failed");
    process.exitCode = 1;
  }
}
