#!/usr/bin/env node

/**
 * 核心 → 公开 adapters 仓（elecon-adapters）的**单向只读镜像**（ADR-018 §2.8 / §2.11 MVP）。
 *
 * 立场（ADR-018 §2.8 所有权）：contract / stdlib / validator / scanner / broker-primitives 的
 * **源真相在私有核心仓**；公开仓只**只读消费** pin 版快照。本脚本把这批受治理/受信任产物
 * vendored 复制进公开仓的 `vendor/`，供其 CI 静态校验（§2.10）。
 *
 * **不镜像**：
 *  - `tools/src/signer`（签名工具属私有核心，绝不发布，ADR-002 §2.3 / ADR-018 §2.8）；
 *  - `adapters/school-*`（社区 adapter 是公开仓源真相，方向相反——核心构建期反向消费之）；
 *  - 公开仓自有文件（package.json / CI / CONTRIBUTING）——那些由公开仓维护，本脚本不碰。
 *
 * 方向严格单向：core → public。**绝不**从 public 回写 core。
 *
 *   运行（在核心仓根）：node scripts/mirror-to-adapters-repo.mjs [公开仓路径]
 *   缺省路径：../elecon-adapters（可用环境变量 ELECON_ADAPTERS_REPO 覆盖）。
 */

import { execSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const coreRoot = fileURLToPath(new URL("../", import.meta.url)); // scripts/ → 仓库根
const target = resolve(
  process.argv[2] ?? process.env.ELECON_ADAPTERS_REPO ?? join(coreRoot, "..", "elecon-adapters"),
);

// 安全闸：目标须是 git 仓库且带 adapters/（避免误写错目录）。
if (!existsSync(join(target, ".git"))) {
  console.error(`✗ 目标不是 git 仓库：${target}`);
  process.exit(1);
}
if (!existsSync(join(target, "adapters"))) {
  console.error(`✗ 目标缺 adapters/，不像 elecon-adapters 仓：${target}`);
  process.exit(1);
}

const vendor = join(target, "vendor");

/** 过滤器：跳过 node_modules / .git / 冒烟测试（公开仓只需可运行的校验器本体）。 */
function skip(src) {
  return !/(^|[/\\])(node_modules|\.git)([/\\]|$)/.test(src) && !/\.smoke\.ts$/.test(src);
}

/** clean + 复制一棵目录到 vendor/<destRel>。 */
function mirrorDir(srcRel, destRel, filter) {
  const src = join(coreRoot, srcRel);
  const dest = join(vendor, destRel);
  if (!existsSync(src)) {
    console.error(`✗ 源缺失：${srcRel}`);
    process.exit(1);
  }
  rmSync(dest, { recursive: true, force: true });
  mkdirSync(dirname(dest), { recursive: true });
  cpSync(src, dest, { recursive: true, filter: filter ?? (() => true) });
  console.log(`  ✓ ${srcRel} → vendor/${destRel}`);
}

console.log(`镜像 core → ${target}`);
rmSync(vendor, { recursive: true, force: true });
mkdirSync(vendor, { recursive: true });

// 1) 契约（红线 #6 承重）
mirrorDir("contract", "contract");
// 2) stdlib（受信任宿主代码；含 package.json 供 stdlibMin 校验 + html.bundle.js）
mirrorDir("adapters/_stdlib", "adapters/_stdlib", skip);
// 3) 脚手架模板（贡献者复制起点）
mirrorDir("adapters/_template", "adapters/_template", skip);
// 4) 闸门逻辑：只镜像 validator + scanner（signer/codegen 不发布）
mirrorDir("tools/src/validator", "tools/src/validator", skip);
mirrorDir("tools/src/scanner", "tools/src/scanner", skip);
// 5) broker-primitives：只发 dist + 精简 package.json（去掉 prepare/build，避免 file: 安装时跑 tsc）
mirrorDir("packages/broker-primitives/dist", "packages/broker-primitives/dist");
const bp = JSON.parse(readFileSync(join(coreRoot, "packages/broker-primitives/package.json"), "utf8"));
const bpMin = {
  name: bp.name,
  version: bp.version,
  private: true,
  type: bp.type,
  main: bp.main,
  types: bp.types,
  exports: bp.exports,
  files: ["dist"],
};
writeFileSync(join(vendor, "packages/broker-primitives/package.json"), `${JSON.stringify(bpMin, null, 2)}\n`);
console.log("  ✓ packages/broker-primitives（dist + 精简 package.json）");

// 6) MIRROR.md：pin 记录 + 勿改声明
const sha = execSync("git rev-parse HEAD", { cwd: coreRoot }).toString().trim();
const stdlibVer = JSON.parse(readFileSync(join(coreRoot, "adapters/_stdlib/package.json"), "utf8")).version;
writeFileSync(
  join(vendor, "MIRROR.md"),
  `# vendor/ — 核心镜像（只读，勿手改）

本目录由 \`scripts/mirror-to-adapters-repo.mjs\` 从私有核心仓 **单向** 生成（ADR-018 §2.8）。
**请勿手工编辑**——任何改动会在下次镜像时被覆盖；contract / stdlib / 校验器的源真相在核心仓。

| 项 | 来源 | 用途 |
|---|---|---|
| \`contract/\` | core \`contract/\` | manifest / capability / schema 契约（validator 据此校验） |
| \`adapters/_stdlib/\` | core \`adapters/_stdlib/\` | \`elecon:html\` stdlib（bundle + 版本，供 stdlibMin 校验）;版本 = ${stdlibVer} |
| \`adapters/_template/\` | core \`adapters/_template/\` | 贡献脚手架 |
| \`tools/src/{validator,scanner}/\` | core \`tools/src/\` | CI 静态闸门（§2.10）;**不含 signer** |
| \`packages/broker-primitives/\` | core \`packages/broker-primitives/dist\` | validator 依赖的 url-match 原语 |

- 源提交（core）：\`${sha}\`
- stdlib 版本：${stdlibVer}

> 若核心 tool 依赖（ajv / ajv-formats / tsx）版本变化，需同步更新公开仓根 \`package.json\`。
`,
);
console.log(`  ✓ vendor/MIRROR.md（core@${sha.slice(0, 8)}, stdlib ${stdlibVer}）`);
console.log("镜像完成。");
