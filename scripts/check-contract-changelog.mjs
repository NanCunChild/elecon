#!/usr/bin/env node
/**
 * 契约变更引用闭环闸门（ADR-001 §8）。
 *
 * ADR-001 §8 把「允许且推荐破坏性更新」的放行条件之一定为：**每次契约变更必须在
 * `contract/CHANGELOG.md` 留一条记录，且记录中必须引用一个 ADR 编号**——记录的存在即证明
 * 该变更「先有 ADR」（红线 #6）。本脚本是该规则的机器校验；在此之前它纯靠自觉。
 *
 * 判据（相对 base ref 的 diff）：
 *   1. 若本次改动触及 WATCHED 路径 → `contract/CHANGELOG.md` 必须**也有新增行**；
 *   2. 且新增行里必须至少出现一个 ADR 编号（`ADR-001` / `adr_001` / `adr_001_contract.md`）。
 *
 * **不判断内容对不对**——那是人的活。它只保证「改了契约却什么都没记」这一形态过不去。
 *
 * 用法：node scripts/check-contract-changelog.mjs [baseRef] [headRef]
 * baseRef 缺省取 $GITHUB_BASE_REF（PR）→ origin/main → main；headRef 缺省 HEAD
 * （显式 headRef 供自测：可对历史区间重放本闸门）。
 */
import { execFileSync } from "node:child_process";

const WATCHED = ["contract/schema/", "contract/capability/", "contract/manifest.schema.json"];
const CHANGELOG = "contract/CHANGELOG.md";
const ADR_REF = /\b(?:ADR[-_ ]?\d{3}|adr_\d{3})\b/i;

// 所有 git 调用都锚在仓库根：pathspec 是**相对 cwd** 解析的，
// 从 tools/ 跑 `git diff -- contract/CHANGELOG.md` 会匹配不到任何东西 → 假阴性放行。
const repoRoot = execFileSync("git", ["rev-parse", "--show-toplevel"], {
  encoding: "utf8",
}).trim();

function git(args) {
  return execFileSync("git", ["-C", repoRoot, ...args], { encoding: "utf8" }).trim();
}

function resolveBase(explicit) {
  const candidates = [
    explicit,
    process.env.GITHUB_BASE_REF && `origin/${process.env.GITHUB_BASE_REF}`,
    "origin/main",
    "main",
  ].filter(Boolean);
  for (const ref of candidates) {
    try {
      git(["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
      return ref;
    } catch {
      // 试下一个
    }
  }
  return null;
}

const base = resolveBase(process.argv[2]);
if (!base) {
  console.error("✗ 找不到可比对的 base ref（试过 $GITHUB_BASE_REF / origin/main / main）。");
  process.exit(2);
}

const head = process.argv[3] ?? "HEAD";
const mergeBase = git(["merge-base", base, head]);
const changed = git(["diff", "--name-only", mergeBase, head]).split("\n").filter(Boolean);
const touched = changed.filter((f) => WATCHED.some((w) => f.startsWith(w)));

if (touched.length === 0) {
  console.log(`契约变更闸门：本次未触及 ${WATCHED.join(" / ")}，跳过。`);
  process.exit(0);
}

console.log(`契约变更闸门（base=${base}）：检出 ${touched.length} 处契约改动`);
for (const f of touched) console.log(`  · ${f}`);

// CHANGELOG 的**新增行**（+ 开头、排除 +++ 文件头）
const changelogDiff = git(["diff", "-U0", mergeBase, head, "--", CHANGELOG]);
const added = changelogDiff
  .split("\n")
  .filter((l) => l.startsWith("+") && !l.startsWith("+++"))
  .map((l) => l.slice(1));

if (added.length === 0) {
  console.error(`\n✗ 改动了 contract/ 却未在 ${CHANGELOG} 新增任何记录（ADR-001 §8）。`);
  console.error("  每次契约变更必须留一条记录，且引用一个 ADR 编号——记录的存在即证明「先有 ADR」。");
  process.exit(1);
}

if (!added.some((l) => ADR_REF.test(l))) {
  console.error(`\n✗ ${CHANGELOG} 的新增内容里没有任何 ADR 编号引用（ADR-001 §8）。`);
  console.error("  无 ADR 引用的条目视为违规——红线 #6 的「先有 ADR」由此条机器校验。");
  console.error("  新增行示例：");
  for (const l of added.slice(0, 5)) console.error(`    ${l.slice(0, 100)}`);
  process.exit(1);
}

console.log(`\n✓ ${CHANGELOG} 有新增记录且引用了 ADR 编号（ADR-001 §8 放行条件满足）。`);
