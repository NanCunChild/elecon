/**
 * 🔴 P0-01 验收红用例：bundle digest 未绑定**路径**导致的保序重命名伪造。
 *
 * 本文件**故意是红的**——它断言的是 P0-01 落地**之后**才成立的安全性质。因此它
 * **不叫 `*.smoke.ts`**（不会被 `run-smokes.mjs` 发现，CI 的 `smoke:all` 保持绿），
 * 只经 `npm run redcase:bundle-path-binding` 显式运行，作为 P0-01 的**验收门**：
 * P0-01 完成的定义 = 本文件全绿；在此之前它必须红，且红的方式必须与下面的诊断一致。
 *
 *     运行：cd tools && npm run redcase:bundle-path-binding
 *
 * ── 缺陷 ─────────────────────────────────────────────────────────────────────
 * 现行 digest（`envelope.ts` / `signer/index.ts`）：
 *
 *     digest = SHA-256( SHA-256(C₁) ‖ SHA-256(C₂) ‖ … )     Cᵢ = 按 path 排序后的**内容**
 *
 * path 只参与**排序**，自身从不进哈希。于是任何**保持字典序位次**的重命名都不改变 digest，
 * 而加载器恰恰是**按 path 取要执行的字节**（Dart `adapter_launcher.dart` 依
 * `manifest.runtime.entry` 线性查找；ADR-026 的 `masker.json` 同理）。二者合起来 =
 * 攻击者可让 official 签名背书「审查时无害的资产文件」作为入口执行。
 *
 * 攻击者模型：ADR-018 信任域 A 的社区贡献者（或任何能把内容放进受审 bundle 的人）。
 * 人工审查看到的是无害目录，**检出率为零**；签名与身份核对（ADR-002 §2.2）全部照常通过。
 * 直接击穿红线 #4。
 *
 * ── 修法（本用例即其验收标准）────────────────────────────────────────────────
 * ADR-002 §2.3 / ADR-018 §2.9 修订：digest 改为**对 envelope 的序列化字节整体哈希**，
 * 并在验签后加**路径卫生闸门**。见两份 ADR 的「digest v2」小节。
 *
 * 🔒 承重路径（红线 #4）。本文件 keyless（只用测试 Ed25519 密钥对，不碰 YubiKey 后端），
 *    可自动化；但 P0-01 的**实现**与本文件转绿的判定须人工复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

import { generateKeyPairSync, type KeyObject } from "node:crypto";
import { LocalDevSignBackend, type SignatureFile } from "../signer/index.js";
import {
  BUNDLE_FORMAT,
  type BundleEnvelope,
  type EnvelopeFile,
  envelopeDigest,
  fileBytes,
} from "./envelope.js";
import { verifyBundleSignature } from "./package.js";
import { signEnvelope } from "./sign.js";

// ---- 微型断言收集器：不 fail-fast，一次给出全部红项（这是验收门，不是调试脚本） ----

interface Failure {
  readonly id: string;
  readonly want: string;
  readonly got: string;
}
const failures: Failure[] = [];
let checked = 0;

function expect(id: string, ok: boolean, want: string, got: string): void {
  checked += 1;
  if (ok) console.log(`  ✓ ${id}`);
  else {
    console.log(`  ✗ ${id}`);
    failures.push({ id, want, got });
  }
}

// ---- 固定的测试 bundle（合成，不用真实 adapter：本用例要精确控制文件名与位次） ----

const EVIL = "/* 审查时是 assets/theme.css，改名后被当作入口执行 */\nglobalThis.__elecon_pwned = true;\n";
const BENIGN = "export function run() {\n  return { ok: true };\n}\n";
const MANIFEST = JSON.stringify(
  {
    adapterId: "school-redcase",
    adapterVersion: "1.0.0",
    runtime: { entry: "index.js", stdlibMin: "1.0.0" },
  },
  null,
  2,
);

function utf8(path: string, content: string): EnvelopeFile {
  return { path, encoding: "utf-8", content };
}

function envOf(files: readonly EnvelopeFile[]): BundleEnvelope {
  return { bundleFormat: BUNDLE_FORMAT, files: [...files] };
}

/** 模拟加载器取入口字节：按 `manifest.runtime.entry` 的 **path** 查找（Dart `_entrySource` 的等价物）。 */
function resolveEntry(env: BundleEnvelope): string {
  const manifest = env.files.find((f) => f.path === "manifest.json");
  if (manifest === undefined) throw new Error("红用例前提破坏：无 manifest.json");
  const entry = (JSON.parse(fileBytes(manifest).toString("utf-8")) as { runtime: { entry: string } }).runtime
    .entry;
  const file = env.files.find((f) => f.path === entry);
  if (file === undefined) throw new Error(`红用例前提破坏：入口 ${entry} 不在 bundle`);
  return fileBytes(file).toString("utf-8");
}

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const backend = new LocalDevSignBackend(privateKey, "redcase-dev");

async function signed(env: BundleEnvelope): Promise<SignatureFile> {
  return signEnvelope(env, "official", backend);
}

function verify(env: BundleEnvelope, sig: SignatureFile, key: KeyObject = publicKey): boolean {
  return verifyBundleSignature(env, sig, key).ok;
}

// ── A. 保序重命名伪造 ────────────────────────────────────────────────────────
//
//   签名时（审查者看到的目录，完全无害）        伪造后（一个字节都没改，只改了名字）
//   ────────────────────────────────────        ─────────────────────────────────
//   1  assets/theme.css → EVIL                  1  index.js        → EVIL   ← 被执行
//   2  index.js         → BENIGN                2  index.js0       → BENIGN
//   3  manifest.json    → MANIFEST              3  manifest.json   → MANIFEST
//
//   两侧「按 path 排序后的内容序列」都是 [EVIL, BENIGN, MANIFEST] → digest 逐字节相同。

console.log("\n━━ A. 保序重命名（order-preserving rename）━━");

const honest = envOf([
  utf8("assets/theme.css", EVIL),
  utf8("index.js", BENIGN),
  utf8("manifest.json", MANIFEST),
]);

const forged = envOf([
  utf8("index.js", EVIL), // 原 assets/theme.css，位次 1 不变
  utf8("index.js0", BENIGN), // 原 index.js，位次 2 不变（index.js < index.js0 < manifest.json）
  utf8("manifest.json", MANIFEST),
]);

const sigHonest = await signed(honest);

// 前提 1：诚实 bundle 正常验过（否则本用例的结论无意义）。
expect("A0 诚实 bundle 验签通过（前提）", verify(honest, sigHonest), "ok=true", "ok=false");

// 前提 2：伪造后入口指向的确实是恶意内容（证明"影响"，非"理论"）。
expect(
  "A1 伪造后入口解析到恶意内容（影响成立，前提）",
  resolveEntry(forged) === EVIL && resolveEntry(honest) === BENIGN,
  "honest→BENIGN, forged→EVIL",
  `honest→${resolveEntry(honest) === BENIGN ? "BENIGN" : "?"}, forged→${resolveEntry(forged) === EVIL ? "EVIL" : "?"}`,
);

// 诊断（非断言）：把"为什么能过"直接打出来。P0-01 落地后这两个 digest 必须不同。
const dHonest = envelopeDigest(honest);
const dForged = envelopeDigest(forged);
console.log(`    digest(honest) = ${dHonest}`);
console.log(`    digest(forged) = ${dForged}`);
console.log(`    → ${dHonest === dForged ? "相同（路径未进 digest，缺陷成立）" : "不同（路径已进 digest）"}`);

// ★ 核心安全性质：改了 path 就必须验签失败。P0-01 落地前**红**。
expect(
  "A2 ★ 只改路径、不改内容 → 必须验签失败",
  !verify(forged, sigHonest),
  "verifyBundleSignature(forged) → ok=false",
  "ok=true（official 签名背书了恶意入口 → 红线 #4 被击穿）",
);

// ── B. 重复路径 ─────────────────────────────────────────────────────────────
//
// envelope 的 files 是数组，未禁止同名条目。TS/Dart 现均取 first-match，但
// ① Dart `List.sort` **不保证稳定**（TS `Array.sort` 保证）→ 同名不同内容时两端可能算出
//    不同 digest（跨语言漂移，ADR-002 §3 风险 5）；
// ② 任一消费方改用 Map（last-wins）即成解析差分。
// 故重复路径必须在验签后被整体拒绝，而非依赖"大家都取第一条"。

console.log("\n━━ B. 重复路径（duplicate path）━━");

const dup = envOf([
  utf8("index.js", BENIGN),
  utf8("index.js", EVIL), // 同名第二条
  utf8("manifest.json", MANIFEST),
]);
const sigDup = await signed(dup);

expect(
  "B1 ★ 含重复路径的 envelope → 即使签名有效也必须拒",
  !verify(dup, sigDup),
  "ok=false（重复路径 fail-closed）",
  "ok=true（重复路径被接受 → 跨端 digest 漂移 + 解析差分）",
);

// ── C. 路径卫生 ─────────────────────────────────────────────────────────────
//
// 签名只证明"发布者确实想要这些字节"，**不**证明这些路径安全。当前 bundle 内容不按 path 落盘
// （`bundle_cache.dart` 以 digest 为 key），故这些是纵深防御；但 ADR-033 本地导入与任何未来的
// 落盘/资产解析都会把它们变成活口子。闸门位置：验签之后、使用之前。

console.log("\n━━ C. 路径卫生（hygiene gate）━━");

const badPaths: ReadonlyArray<readonly [string, string]> = [
  ["C1 上跳 `..`", "../evil.js"],
  ["C2 内嵌 `..`", "assets/../../evil.js"],
  ["C3 绝对路径（POSIX）", "/etc/evil.js"],
  ["C4 绝对路径（Windows 盘符）", "C:/evil.js"],
  ["C5 反斜杠分隔", "assets\\evil.js"],
  ["C6 单点 `.` 段", "./index.js"],
  ["C7 空路径", ""],
  ["C8 尾随分隔符", "assets/"],
  ["C9 NUL 字节", "assets/evil\u0000.js"],
];

for (const [id, path] of badPaths) {
  const env = envOf([utf8(path, BENIGN), utf8("index.js", BENIGN), utf8("manifest.json", MANIFEST)]);
  let ok: boolean;
  try {
    ok = !verify(env, await signed(env));
  } catch {
    ok = true; // 签发期就拒也算通过（fail-closed 越早越好）
  }
  expect(`${id} ★ \`${path}\` → 必须拒`, ok, "ok=false", "ok=true（畸形路径被接受）");
}

// ── D. bundleFormat 未进 digest ─────────────────────────────────────────────
//
// `envelopeDigest` 只遍历 files，`bundleFormat` 完全在签名之外 → 格式标识可被任意翻改。
// 现在只有一个格式所以无即时影响；elecon-bundle/2 一出，这就是降级面。

console.log("\n━━ D. 格式标识绑定（bundleFormat）━━");

const flipped: BundleEnvelope = { ...honest, bundleFormat: "elecon-bundle/9" };
expect(
  "D1 ★ 篡改 bundleFormat → 必须验签失败",
  !verify(flipped, sigHonest),
  "ok=false",
  "ok=true（格式标识不在签名范围 → 可降级）",
);

// ── 汇总 ────────────────────────────────────────────────────────────────────

console.log("\n" + "─".repeat(78));
if (failures.length === 0) {
  console.log(`P0-01 验收红用例：${checked}/${checked} 全绿 ✅ —— digest 已绑定路径、卫生闸门已生效。`);
  console.log("下一步：本文件可改名为 `path-binding.smoke.ts` 纳入 smoke:all 常驻回归。");
  process.exit(0);
}

console.log(
  `🔴 P0-01 未落地：${checked - failures.length}/${checked} 项通过，${failures.length} 项安全性质不成立\n`,
);
for (const f of failures) {
  console.log(`  ${f.id}`);
  console.log(`      期望：${f.want}`);
  console.log(`      实际：${f.got}`);
}
console.log("\n本红用例是 P0-01 的验收门：修订 ADR-002 §2.3 / ADR-018 §2.9.1 的 digest v2 落地后应全绿。");
console.log(
  [
    "",
    "以下断言**当前无法表达**——它们针对 descriptor 形态的 envelope（ADR-018 §2.9.1），",
    "而现行类型里既无 `files[].sha256/size`，也无 `blobs` 表。实现落地时须同批补入本文件：",
    "  E1 blob 表多一个（未被任何 descriptor 引用）→ 必须拒（夹带通道，验证第 9 步）",
    "  E2 blob 表少一个（descriptor 引用了不存在的 blob）→ 必须拒",
    "  E3 blob 解码后哈希不命中 descriptor.sha256 → 必须拒",
    "  E4 blob 解码后长度 ≠ descriptor.size → 必须拒（先按 size 界定再解码，防 endless-data）",
    "  E5 envelope 顶层 adapterId/Version ≠ manifest.json 内容 → 必须拒（三方一致，第 11 步）",
    "  E6 envelope 顶层身份 ≠ 签名载荷身份 → 必须拒",
    "  E7 签名载荷缺 contextTag 或用了别的域（如 elecon.catalog/1）→ 必须拒（域分隔）",
    "  E8 传输封套含多余字段 → 必须拒（验签前解析面最小化）",
  ].join("\n"),
);
process.exit(1);
