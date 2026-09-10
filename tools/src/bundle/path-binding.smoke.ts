/**
 * 🔴 P0-01 验收门：bundle digest 的**路径绑定**与 digest v2 的全部配套不变量。
 *
 * 本文件原本叫 `path-binding.redcase.ts`：它断言的是 P0-01 落地**之后**才成立的安全性质，
 * 在落地前必须是红的，故刻意不叫 `*.smoke.ts`（不被 `run-smokes.mjs` 发现，CI 保持绿）。
 * **P0-01 完成的定义 = 本文件全绿**，已于 2026-09-09 达成（26/26），据此改名纳入 `smoke:all`
 * 常驻回归——从此它守的不再是「修好了没」，而是「有没有被改回去」。
 *
 *     运行：cd tools && npm run smoke:bundle-path-binding
 *
 * ── 原缺陷（v1，已由 digest v2 修掉）────────────────────────────────────────
 *
 *     digest = SHA-256( SHA-256(C₁) ‖ SHA-256(C₂) ‖ … )     Cᵢ = 按 path 排序后的**内容**
 *
 * path 只参与**排序**，自身从不进哈希 → 任何**保持字典序位次**的重命名都不改变 digest，
 * 而加载器恰恰是**按 path 取要执行的字节**。二者合起来 = 攻击者可让 official 签名背书
 * 「审查时无害的资产文件」作为入口执行。人工审查检出率为零，直接击穿红线 #4。
 * 完整复现与四个被否方案见 `docs/archive/bundle_digest_v1_superseded.md`。
 *
 * ── digest v2（ADR-002 §2.3 / ADR-018 §2.9.1）────────────────────────────────
 *
 *     envelope = { bundleFormat, adapterId, adapterVersion, files:[{path,size,sha256}] }
 *     digest   = SHA-256( envelopeBytes )
 *     on-wire  = gzip(JSON({ envelopeB64, signature, blobs }))
 *
 * 路径 / 大小 / 顺序 / 文件个数 / 格式标识 / 身份**全部进签名范围**。本文件的分组即
 * 「digest v2 的六条纪律各自坏掉时会怎样」：
 *
 *   A 保序重命名（v1 的原病灶）        D 格式标识绑定（纪律 6）
 *   B 重复路径（跨端解析差分）          E1–E4 blob 表纪律（纪律 4）
 *   C 路径卫生闸门（纪律 3）            E5–E6 身份三方一致
 *                                       E7 签名域分隔  E8 封套解析面最小化  E9 非规范 base64
 *
 * 🔒 承重路径（红线 #4）。本文件 keyless（只用测试 Ed25519 密钥对，不碰 YubiKey 后端），
 *    可自动化；但 P0-01 的**实现**与本文件转绿的判定须人工复核，不得 AI 独自闭环（AGENTS.md §1）。
 */

import { generateKeyPairSync, type KeyObject } from "node:crypto";
import { gzipSync } from "node:zlib";
import {
  CONTEXT_TAG_BUNDLE,
  CONTEXT_TAG_CATALOG,
  LocalDevSignBackend,
  type SignatureFile,
  serializePayload,
  withContext,
} from "../signer/index.js";
import {
  type BlobTable,
  BUNDLE_FORMAT,
  type BuiltBundle,
  type BundleEnvelope,
  type EnvelopeFileDescriptor,
  fileBytesByPath,
  serializeEnvelope,
  sha256Hex,
} from "./envelope.js";
import { openBundle, packBundle } from "./package.js";
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

const ID = "school-redcase";
const VERSION = "1.0.0";

function manifestOf(adapterId = ID, adapterVersion = VERSION): string {
  return JSON.stringify(
    { adapterId, adapterVersion, runtime: { entry: "index.js", stdlibMin: "1.0.0" } },
    null,
    2,
  );
}
const MANIFEST = manifestOf();

/**
 * 合成一份 bundle。**刻意不走 `buildEnvelope`**：那条路会做卫生闸门与全量承诺检查，
 * 而本文件正需要构造出「签发侧本不该产出、但攻击者可以拼出来」的畸形 envelope，
 * 以验证**收端**（`openBundle`）自己拦得住，而不是依赖「签端应该不会那么干」。
 */
function synth(
  entries: ReadonlyArray<readonly [path: string, content: string]>,
  opts: { adapterId?: string; adapterVersion?: string; bundleFormat?: string } = {},
): BuiltBundle {
  const blobs: BlobTable = {};
  const files: EnvelopeFileDescriptor[] = entries.map(([path, content]) => {
    const raw = Buffer.from(content, "utf-8");
    const hash = sha256Hex(raw);
    blobs[hash] = raw;
    return { path, size: raw.length, sha256: hash };
  });
  const envelope: BundleEnvelope = {
    bundleFormat: opts.bundleFormat ?? BUNDLE_FORMAT,
    adapterId: opts.adapterId ?? ID,
    adapterVersion: opts.adapterVersion ?? VERSION,
    files,
  };
  return { envelope, bytes: serializeEnvelope(envelope), blobs };
}

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const backend = new LocalDevSignBackend(privateKey, "redcase-dev");

async function signed(built: BuiltBundle): Promise<SignatureFile> {
  return signEnvelope(built, "official", backend);
}

/** 收端全链路：pack → open。返回 `ok` 与失败原因（原因用于确认「拒对了地方」）。 */
function open(
  built: BuiltBundle,
  sig: SignatureFile,
  key: KeyObject = publicKey,
  blobs: BlobTable = built.blobs,
): { ok: boolean; reason: string } {
  const r = openBundle(packBundle(built.bytes, sig, blobs), key);
  return r.ok ? { ok: true, reason: "" } : { ok: false, reason: r.reason };
}

/** 模拟加载器取入口字节：按 `manifest.runtime.entry` 的 **path** 查找。 */
function resolveEntry(built: BuiltBundle): string {
  const manifestBytes = fileBytesByPath(built.envelope, built.blobs, "manifest.json");
  if (manifestBytes === null) throw new Error("红用例前提破坏：无 manifest.json");
  const entry = (JSON.parse(manifestBytes.toString("utf-8")) as { runtime: { entry: string } }).runtime.entry;
  const bytes = fileBytesByPath(built.envelope, built.blobs, entry);
  if (bytes === null) throw new Error(`红用例前提破坏：入口 ${entry} 不在 bundle`);
  return bytes.toString("utf-8");
}

// ── A. 保序重命名伪造（v1 的原病灶）─────────────────────────────────────────
//
//   签名时（审查者看到的目录，完全无害）        伪造后（一个字节都没改，只改了名字）
//   ────────────────────────────────────        ─────────────────────────────────
//   1  assets/theme.css → EVIL                  1  index.js        → EVIL   ← 被执行
//   2  index.js         → BENIGN                2  index.js0       → BENIGN
//   3  manifest.json    → MANIFEST              3  manifest.json   → MANIFEST
//
//   v1 下两侧「按 path 排序后的内容序列」都是 [EVIL, BENIGN, MANIFEST] → digest 逐字节相同。
//   v2 下 path 在被哈希的字节里 → digest 必不同。

console.log("\n━━ A. 保序重命名（order-preserving rename）━━");

const honest = synth([
  ["assets/theme.css", EVIL],
  ["index.js", BENIGN],
  ["manifest.json", MANIFEST],
]);

const forged = synth([
  ["index.js", EVIL], // 原 assets/theme.css，位次 1 不变
  ["index.js0", BENIGN], // 原 index.js，位次 2 不变（index.js < index.js0 < manifest.json）
  ["manifest.json", MANIFEST],
]);

const sigHonest = await signed(honest);

// 前提 1：诚实 bundle 正常验过（否则本用例的结论无意义）。
const a0 = open(honest, sigHonest);
expect("A0 诚实 bundle 验签通过（前提）", a0.ok, "ok=true", `ok=false：${a0.reason}`);

// 前提 2：伪造后入口指向的确实是恶意内容（证明「影响」，非「理论」）。
expect(
  "A1 伪造后入口解析到恶意内容（影响成立，前提）",
  resolveEntry(forged) === EVIL && resolveEntry(honest) === BENIGN,
  "honest→BENIGN, forged→EVIL",
  `honest→${resolveEntry(honest) === BENIGN ? "BENIGN" : "?"}, forged→${resolveEntry(forged) === EVIL ? "EVIL" : "?"}`,
);

// 前提 3：**两侧的内容集合完全相同**——这正是 v1 栽跟头的地方。若这条不成立，
// A2 的通过就可能只是因为「内容变了」，而不是因为「路径进了签名范围」。
const blobKeys = (b: BuiltBundle): string => Object.keys(b.blobs).sort().join(",");
expect(
  "A1b 两侧内容（blob 集合）逐字节相同——排除「靠内容变化侥幸拒掉」（前提）",
  blobKeys(honest) === blobKeys(forged),
  "honest.blobs ≡ forged.blobs",
  `honest=${blobKeys(honest).slice(0, 24)}… forged=${blobKeys(forged).slice(0, 24)}…`,
);

// 诊断（非断言）：把「为什么拒得住」直接打出来。
console.log(`    digest(honest) = ${sha256Hex(honest.bytes)}`);
console.log(`    digest(forged) = ${sha256Hex(forged.bytes)}`);
console.log(
  `    → ${sha256Hex(honest.bytes) === sha256Hex(forged.bytes) ? "相同（路径未进 digest，缺陷成立）" : "不同（路径已进 digest ✅）"}`,
);

// ★ 核心安全性质：改了 path 就必须验签失败。
const a2 = open(forged, sigHonest);
expect(
  "A2 ★ 只改路径、不改内容 → 必须拒",
  !a2.ok,
  "ok=false",
  "ok=true（official 签名背书了恶意入口 → 红线 #4 被击穿）",
);

// ── B. 重复路径 ─────────────────────────────────────────────────────────────
//
// envelope 的 files 是数组，结构上不禁止同名条目。TS/Dart 现均取 first-match，但
// ① Dart `List.sort` **不保证稳定**（TS `Array.sort` 保证）→ 同名不同内容时两端可能算出
//    不同结果（跨语言漂移，ADR-002 §3 风险 5）；
// ② 任一消费方改用 Map（last-wins）即成解析差分。
// 故重复路径必须在验签**之后**被整体拒绝，而非依赖「大家都取第一条」。

console.log("\n━━ B. 重复路径（duplicate path）━━");

const dup = synth([
  ["index.js", BENIGN],
  ["index.js", EVIL], // 同名第二条
  ["manifest.json", MANIFEST],
]);
const b1 = open(dup, await signed(dup));
expect(
  "B1 ★ 含重复路径的 envelope → 即使签名有效也必须拒",
  !b1.ok && /重复路径/.test(b1.reason),
  "ok=false（重复路径 fail-closed）",
  b1.ok ? "ok=true（重复路径被接受 → 跨端漂移 + 解析差分）" : `拒了但原因不对：${b1.reason}`,
);

// ── C. 路径卫生 ─────────────────────────────────────────────────────────────
//
// 签名只证明「发布者确实想要这些字节」，**不**证明这些路径安全——哈希再多字节也不会让
// `../../` 变安全。当前 bundle 内容不按 path 落盘（`bundle_cache.dart` 以 digest 为 key），
// 故其中一部分是纵深防御；但 ADR-033 本地导入与任何未来的落盘/资产解析都会把它们变成活口子。
// 闸门位置：验签之后、使用之前（纪律 3）。

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
  ["C10 非 NFC 路径", "assets/e\u0301vil.js"], // 与 assertCanonical 同一取向：拒，不规范化
];

for (const [id, path] of badPaths) {
  const built = synth([
    [path, BENIGN],
    ["index.js", BENIGN],
    ["manifest.json", MANIFEST],
  ]);
  let ok: boolean;
  let got: string;
  try {
    const r = open(built, await signed(built));
    ok = !r.ok;
    got = r.ok ? "ok=true（畸形路径被接受）" : `ok=false：${r.reason}`;
  } catch (err) {
    ok = true; // 签发期就拒也算通过（fail-closed 越早越好）
    got = `签发期即拒：${(err as Error).message}`;
  }
  expect(`${id} ★ \`${path}\` → 必须拒`, ok, "ok=false", got);
}

// ── D. 格式标识绑定 ─────────────────────────────────────────────────────────
//
// v1 的 `envelopeDigest` 只遍历 files，`bundleFormat` 完全在签名之外 → 格式标识可被任意翻改。
// v2 起它在被哈希的字节里，且 `parseEnvelope` 做**严格相等**（不是「以 elecon-bundle/ 开头」）：
// 两道锁，任缺其一都会在 v3 出现时变成降级面（纪律 6）。

console.log("\n━━ D. 格式标识绑定（bundleFormat）━━");

// D1：拿诚实签名去配一个翻改了 bundleFormat 的 envelope —— 字节变了，第 5 步 digest 就拒。
const flipped = synth(
  [
    ["assets/theme.css", EVIL],
    ["index.js", BENIGN],
    ["manifest.json", MANIFEST],
  ],
  { bundleFormat: "elecon-bundle/9" },
);
const d1 = open(flipped, sigHonest);
expect(
  "D1 ★ 篡改 bundleFormat（用原签名）→ 必须拒",
  !d1.ok,
  "ok=false",
  d1.ok ? "ok=true（格式标识不在签名范围 → 可降级）" : `ok=false：${d1.reason}`,
);

// D2：**重新签**一份 bundleFormat=/9 的 —— 签名、digest 全真，只有格式不对。
// 这才测得到 `parseEnvelope` 的严格相等本身（D1 在更早的一步就被拒了，测不到第 7 步）。
const d2 = open(flipped, await signed(flipped));
expect(
  "D2 ★ 重签的 elecon-bundle/9（digest 与签名皆真）→ 第 7 步必须拒",
  !d2.ok && /bundleFormat/.test(d2.reason),
  "ok=false（bundleFormat 严格相等）",
  d2.ok ? "ok=true（可被诱导按未知格式解析 → 降级面）" : `拒了但原因不对：${d2.reason}`,
);

// ── E. digest v2 的新增不变量（descriptor 形态特有）──────────────────────────
//
// 这一组在 v1 下**无法表达**：v1 的 envelope 既无 `files[].sha256/size`，也无 blob 表。

console.log("\n━━ E. blob 表 / 身份 / 域分隔 / 封套（digest v2 新增）━━");

// E1 blob 表多一个 —— **v2 唯一新增的、可以搞砸的不变量**。
//    少一个会被逐文件校验（第 10 步）抓到，**多一个不会**：descriptor 全都能对上，
//    多出来的那个只是「没人引用」。若不显式拒，它就是一条完美的夹带通道——签名照过、
//    审查看不见（审查看的是 envelope 清单），而任何按 sha256 取 blob 的消费方都能取到它。
{
  const smuggled: BlobTable = { ...honest.blobs };
  const extra = Buffer.from("夹带的第二段代码\n", "utf-8");
  smuggled[sha256Hex(extra)] = extra;
  const r = open(honest, sigHonest, publicKey, smuggled);
  expect(
    "E1 ★ blob 表多一个（未被任何 descriptor 引用）→ 必须拒",
    !r.ok && /多出|夹带/.test(r.reason),
    "ok=false（夹带通道，第 9 步）",
    r.ok ? "ok=true（夹带通道敞开）" : `拒了但原因不对：${r.reason}`,
  );
}

// E2 blob 表少一个（descriptor 引用了不存在的 blob）。
{
  const missing: BlobTable = { ...honest.blobs };
  const victim = honest.envelope.files.find((f) => f.path === "index.js")!;
  delete missing[victim.sha256];
  const r = open(honest, sigHonest, publicKey, missing);
  expect(
    "E2 ★ blob 表少一个 → 必须拒",
    !r.ok,
    "ok=false（第 9 步）",
    r.ok ? "ok=true（清单承诺的文件可以不到货）" : `ok=false：${r.reason}`,
  );
}

// E3 blob 内容哈希不命中 descriptor.sha256。
//    刻意**等长**替换，以把这一项与 E4（长度）分开——否则长度检查先拒，测不到哈希这一步。
{
  const victim = honest.envelope.files.find((f) => f.path === "index.js")!;
  const original = honest.blobs[victim.sha256]!;
  const swapped = Buffer.from(original); // 等长
  swapped[0] = swapped[0]! ^ 0x01; // 翻一个 bit
  const tampered: BlobTable = { ...honest.blobs, [victim.sha256]: swapped };
  const r = open(honest, sigHonest, publicKey, tampered);
  expect(
    "E3 ★ blob 内容哈希 ≠ descriptor.sha256（等长替换）→ 必须拒",
    !r.ok && /哈希/.test(r.reason),
    "ok=false（第 10 步内容寻址）",
    r.ok ? "ok=true（blob 键与内容脱钩 → 内容寻址失效）" : `拒了但原因不对：${r.reason}`,
  );
}

// E4 blob 长度 ≠ descriptor.size。
//    **先按 size 界定再解码**是 TUF 携带 length 的同一理由（防 endless-data）：
//    descriptor 说 12 字节，来的是 12 MiB，不能等哈希算完才发现。
{
  const lying = synth([
    ["index.js", BENIGN],
    ["manifest.json", MANIFEST],
  ]);
  const victim = lying.envelope.files.find((f) => f.path === "index.js")!;
  victim.size = victim.size + 4096; // descriptor 撒谎，内容与哈希都真
  lying.envelope.files.sort((a, b) => (a.path < b.path ? -1 : 1));
  const rebuilt: BuiltBundle = {
    envelope: lying.envelope,
    bytes: serializeEnvelope(lying.envelope),
    blobs: lying.blobs,
  };
  const r = open(rebuilt, await signed(rebuilt));
  expect(
    "E4 ★ blob 长度 ≠ descriptor.size（哈希仍命中）→ 必须拒",
    !r.ok && /长度/.test(r.reason),
    "ok=false（第 10 步 size 界定）",
    r.ok ? "ok=true（size 形同虚设 → endless-data）" : `拒了但原因不对：${r.reason}`,
  );
}

// E5 envelope 顶层身份 ≠ manifest.json 内容（三方一致的第一条边）。
//    envelope 顶层身份是**核对副本**，manifest.json 才是权威——两者分叉时必须拒，
//    绝不能「就近取一个」（取顶层 = 身份可脱离被签内容自由声明）。
{
  const mismatch = synth(
    [
      ["index.js", BENIGN],
      ["manifest.json", MANIFEST], // 内容里写的是 school-redcase
    ],
    { adapterId: "school-other" }, // 顶层写的是 school-other
  );
  const r = open(mismatch, await signed(mismatch));
  expect(
    "E5 ★ envelope 顶层身份 ≠ manifest.json → 必须拒",
    !r.ok && /身份/.test(r.reason),
    "ok=false（第 11 步）",
    r.ok ? "ok=true（身份可脱离被签内容声明）" : `拒了但原因不对：${r.reason}`,
  );
}

// E6 签名载荷身份 ≠ envelope 顶层身份（三方一致的第二条边）。
//    digest 真、Ed25519 真——唯一拦得住的就是身份核对（ADR-002 §2.2 身份混淆）。
{
  const payload = serializePayload({
    adapterId: "school-evil",
    adapterVersion: "9.9.9",
    tier: "official",
    digest: sha256Hex(honest.bytes),
  });
  const forgedSig: SignatureFile = {
    adapterId: "school-evil",
    adapterVersion: "9.9.9",
    tier: "official",
    digest: sha256Hex(honest.bytes),
    signature: await backend.sign(payload),
    keyId: "redcase-dev",
    algorithm: "ed25519",
  };
  const r = open(honest, forgedSig);
  expect(
    "E6 ★ 签名载荷身份 ≠ envelope 顶层（digest 与签名皆真）→ 必须拒",
    !r.ok && /身份/.test(r.reason),
    "ok=false（第 11 步）",
    r.ok ? "ok=true（身份混淆：内容 A / 身份 B）" : `拒了但原因不对：${r.reason}`,
  );
}

// E7 签名域分隔：同一把密钥下，别的协议的签名不得在 bundle 这里被接受。
//    v2 之前三个签名对象只靠「JSON 形状恰好互不满足对方 schema」**偶然**隔开。
{
  const digest = sha256Hex(honest.bytes);
  // 剥掉 serializePayload 加的 bundle 前缀，得到裸的规范化载荷字节（不重复实现键序）。
  const bare = serializePayload({
    adapterId: ID,
    adapterVersion: VERSION,
    tier: "official",
    digest,
  }).subarray(CONTEXT_TAG_BUNDLE.length + 1);

  // E7a：完全不带 contextTag 的签名（v2 之前的签法）。
  const noTag: SignatureFile = {
    adapterId: ID,
    adapterVersion: VERSION,
    tier: "official",
    digest,
    signature: await backend.sign(bare),
    keyId: "redcase-dev",
    algorithm: "ed25519",
  };
  const r1 = open(honest, noTag);
  expect(
    "E7a ★ 无 contextTag 的签名（v2 前的签法）→ 必须拒",
    !r1.ok && /验签/.test(r1.reason),
    "ok=false（域分隔，第 6 步）",
    r1.ok ? "ok=true（跨版本重放）" : `拒了但原因不对：${r1.reason}`,
  );

  // E7b：带**别的域**（catalog）的签名 —— 同一把密钥、同一份字节，只是域不同。
  const wrongTag: SignatureFile = {
    ...noTag,
    signature: await backend.sign(withContext(CONTEXT_TAG_CATALOG, bare)),
  };
  const r2 = open(honest, wrongTag);
  expect(
    "E7b ★ 用 elecon.catalog/1 域签的 → 在 bundle 这里必须拒",
    !r2.ok && /验签/.test(r2.reason),
    "ok=false（跨协议重放被域分隔挡住）",
    r2.ok ? "ok=true（同密钥下的签名可跨协议互换）" : `拒了但原因不对：${r2.reason}`,
  );
}

// E8 传输封套含多余字段 → 必须拒。
//    封套是**验签之前唯一被解析的东西**，其解析面必须最小：三字段，严格封闭。
//    任何「多余字段先忽略着」的宽容都是攻击者在验签前可以自由投喂的输入。
{
  const wire = {
    envelopeB64: honest.bytes.toString("base64"),
    signature: sigHonest,
    blobs: Object.fromEntries(Object.entries(honest.blobs).map(([h, b]) => [h, b.toString("base64")])),
    extra: "验签前的自由输入",
  };
  const r = openBundle(gzipSync(Buffer.from(JSON.stringify(wire), "utf-8")), publicKey);
  expect(
    "E8 ★ 传输封套含多余字段 → 必须拒",
    !r.ok && /多余字段/.test(r.reason),
    "ok=false（验签前解析面最小化，第 2 步）",
    r.ok ? "ok=true（验签前解析面可被任意扩展）" : `拒了但原因不对：${r.reason}`,
  );
}

// E9 非规范 base64 → 必须拒（§2.9.1 第 3 步）。
//    Buffer.from(s, "base64") 宽松：忽略空白 / 字母表外字符、接受 URL-safe 字母表。只要解码字节命中
//    digest 就会被放行——内容寻址让这没有信任面影响，但 Dart 是严格的，两端必须同判（风险 5）。
{
  const wireOf = (envelopeB64: string, blobs: Record<string, string>) =>
    gzipSync(Buffer.from(JSON.stringify({ envelopeB64, signature: sigHonest, blobs }), "utf-8"));
  const envB64 = honest.bytes.toString("base64");
  const blobsB64 = Object.fromEntries(
    Object.entries(honest.blobs).map(([h, b]) => [h, b.toString("base64")]),
  );
  const [firstBlobHash, firstBlobB64] = Object.entries(blobsB64)[0]!;
  const variants: Array<[string, string, Record<string, string>]> = [
    ["E9a ★ envelopeB64 内嵌空白", `${envB64.slice(0, 8)} \n${envB64.slice(8)}`, blobsB64],
    ["E9b ★ envelopeB64 尾部追加字母表外字符", `${envB64}!!!`, blobsB64],
    (() => {
      // URL-safe 变体只对含 `+`/`/` 的串有意义：优先 envelope，否则找一个 blob；都没有则用例自身无效（前提断言会红）。
      const toUrlSafe = (x: string) => x.replace(/\+/g, "-").replace(/\//g, "_");
      if (/[+/]/.test(envB64)) return ["E9c ★ envelopeB64 用 URL-safe 字母表", toUrlSafe(envB64), blobsB64];
      const hit = Object.entries(blobsB64).find(([, b]) => /[+/]/.test(b));
      return hit
        ? ["E9c ★ blob 用 URL-safe 字母表", envB64, { ...blobsB64, [hit[0]]: toUrlSafe(hit[1]) }]
        : ["E9c ★ URL-safe 字母表（无可替换字符，用例无效）", "", blobsB64];
    })() as [string, string, Record<string, string>],
    [
      "E9d ★ blob 内嵌空白",
      envB64,
      { ...blobsB64, [firstBlobHash]: `${firstBlobB64.slice(0, 4)} ${firstBlobB64.slice(4)}` },
    ],
  ];
  // 前提：宽松解码下这些变体确实解出同一份字节（否则「拒」可能只是碰巧撞上 digest 不符）。
  expect(
    "E9 前提：变体在宽松解码下与诚实字节相同，且每个变体确实与规范形不同",
    variants.every(
      ([, e, b]) => Buffer.from(e, "base64").equals(honest.bytes) && (e !== envB64 || b !== blobsB64),
    ) &&
      Object.entries(variants[3]![2]).every(([h, b]) => Buffer.from(b, "base64").equals(honest.blobs[h]!)) &&
      Object.entries(variants[2]![2]).every(([h, b]) => Buffer.from(b, "base64").equals(honest.blobs[h]!)),
    "宽松解码后逐字节相同",
    "变体在宽松解码下已不同（测试自身无效）",
  );
  for (const [id, e, b] of variants) {
    const r = openBundle(wireOf(e, b), publicKey);
    expect(
      id,
      !r.ok && /非规范 base64/.test(r.reason),
      "ok=false（第 3 步：非规范 base64 拒）",
      r.ok ? "ok=true（宽松解码放行）" : `拒了但原因不对：${r.reason}`,
    );
  }
}

// ── 汇总 ────────────────────────────────────────────────────────────────────

console.log("\n" + "─".repeat(78));
if (failures.length === 0) {
  console.log(`bundle 路径绑定：${checked}/${checked} 全绿 ✅ —— digest 已绑定路径，六条纪律均已生效。`);
  process.exit(0);
}

console.log(
  `🔴 ${checked - failures.length}/${checked} 项通过，${failures.length} 项安全性质**已回退**——` +
    `digest v2 的某条纪律被改坏了。\n`,
);
for (const f of failures) {
  console.log(`  ${f.id}`);
  console.log(`      期望：${f.want}`);
  console.log(`      实际：${f.got}`);
}
console.log("\n本文件是 digest v2（ADR-002 §2.3 / ADR-018 §2.9.1）的回归门，任一项红都不得合并。");
process.exit(1);
