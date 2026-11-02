/** ADR-052: independently installable, school-bound Chaoxing enhancements. */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { packageScript } from "./package.js";

const root = fileURLToPath(new URL("../../../school-scripts/xidian-chaoxing/", import.meta.url));
export async function buildChaoxingPackages(): Promise<Map<string, string>> {
  const output = await build({
    absWorkingDir: root,
    entryPoints: [join(root, "src/index.js")],
    bundle: true,
    write: false,
    format: "esm",
    platform: "neutral",
    target: "es2020",
    external: ["elecon:html"],
    legalComments: "inline",
    charset: "utf8",
    logLevel: "silent",
  });
  const packages = new Map<string, string>();
  for (const file of ["manifest.json", "postgraduate.manifest.json"]) {
    const manifest = JSON.parse(await readFile(join(root, file), "utf8"));
    packages.set(`${manifest.id}.elecon.json`, packageScript(manifest, output.outputFiles[0]!.text));
  }
  return packages;
}
export async function writeChaoxingPackages(directory: string): Promise<void> {
  const packages = await buildChaoxingPackages();
  await mkdir(directory, { recursive: true });
  for (const [name, content] of packages) await writeFile(join(directory, name), content);
  await writeFile(join(directory, "CHAOXING-LICENSE.txt"), await readFile(join(root, "LICENSE")));
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length && (args.length !== 2 || args[0] !== "--out-dir"))
    throw new Error("usage: --out-dir directory");
  const caller = process.env.INIT_CWD ?? process.cwd();
  await writeChaoxingPackages(args[1] ? resolve(caller, args[1]) : join(root, "dist"));
  console.log("chaoxing_packages_created");
}
