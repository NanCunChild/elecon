import { build } from "esbuild";

await build({
  entryPoints: ["src/html.ts"],
  bundle: true,
  format: "esm",
  target: "es2020",
  outfile: "html.bundle.js",
  platform: "neutral",
  mainFields: ["module", "main"],
  minify: false,
  sourcemap: false,
});

console.log("✓ html.bundle.js built");
