/**
 * signer 冒烟测试 —— 仅覆盖**确定性、无密钥**部分：规范化断言、签名域分隔、
 * payload 键序、revocation 纯判定（kill-switch / 最低版本 / digest / 版本区间）、semver 比较。
 *
 * 🔒 **有意不包含** Ed25519 sign/verify 往返测试与密钥加载——签名操作是承重路径，
 *    其代码与测试须由维护者人工闭环（AGENTS.md §1，ADR-002 §2.3）。
 *
 * digest v2 起，「从目录算 digest」不再是 signer 的职责（`computeBundleDigest` 已删，
 * 唯一实现是 `bundle/envelope.ts` 的 `buildEnvelope` → `envelopeDigest`）。故此处只测
 * signer 保留的**无方向性原语**；digest 本身的行为在 `bundle/bundle.smoke.ts` 测。
 *
 *   运行：cd tools && npm run smoke:signer
 */

import { strict as assert } from "node:assert";
import {
  assertCanonical,
  CONTEXT_TAG_BUNDLE,
  CONTEXT_TAG_CATALOG,
  CONTEXT_TAG_REVOCATION,
  serializePayload,
  withContext,
} from "./index.js";
import { compareSemver, isRevoked, pickNewer, type RevocationList, signRevocation } from "./revocation.js";

// ---- 规范化：**断言而非改写**（digest v2 改判，ADR-002 §2.3） ----

{
  // 已规范化的文本：LF 换行 + NFC，放行。
  assert.doesNotThrow(
    () => assertCanonical("index.js", Buffer.from("é\nline\n\n", "utf-8")),
    "NFC + LF 文本应放行",
  );

  // CRLF：拒（不再静默改写成 LF）。
  assert.throws(
    () => assertCanonical("index.js", Buffer.from("line\r\n", "utf-8")),
    /CR\/CRLF/,
    "CRLF 必须拒签，而非改写",
  );

  // 非 NFC（e + U+0301 组合重音）：拒。
  assert.throws(
    () => assertCanonical("index.js", Buffer.from("e\u0301\n", "utf-8")),
    /NFC/,
    "非 NFC 必须拒签，而非改写",
  );

  // 真二进制（非 UTF-8 可解码）：跳过文本规范化，放行——否则 png/ico 等资产永远签不出去。
  assert.doesNotThrow(
    () => assertCanonical("assets/icon.png", Buffer.from([0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe])),
    "真二进制应跳过文本规范化断言",
  );

  console.log("✓ assertCanonical：NFC/LF 不符即拒（不改写）、二进制放行");
}

// ---- 签名域分隔（同一把密钥下多个签名协议必须显式隔离） ----

{
  const body = Buffer.from('{"x":1}', "utf-8");
  const tagged = withContext(CONTEXT_TAG_BUNDLE, body);

  assert.strictEqual(tagged[CONTEXT_TAG_BUNDLE.length], 0x00, "tag 与正文之间须有 0x00 分隔符");
  assert.ok(
    tagged.subarray(0, CONTEXT_TAG_BUNDLE.length).toString("utf-8") === CONTEXT_TAG_BUNDLE,
    "前缀须是 contextTag 本身",
  );
  assert.ok(
    tagged.subarray(CONTEXT_TAG_BUNDLE.length + 1).equals(body),
    "正文须原样保留在分隔符之后（传输对象不变，前缀只加在签/验输入上）",
  );

  // 三个域两两不同，且**没有任何一个是另一个的前缀**——否则 0x00 分隔仍可能被绕过。
  const tags = [CONTEXT_TAG_BUNDLE, CONTEXT_TAG_CATALOG, CONTEXT_TAG_REVOCATION];
  assert.strictEqual(new Set(tags).size, 3, "三个 contextTag 必须互不相同");
  for (const a of tags) {
    for (const b of tags) {
      if (a === b) continue;
      assert.ok(!a.startsWith(b), `contextTag ${a} 不得以 ${b} 为前缀`);
    }
  }

  // 跨域不可互换：同一份正文在不同域下的待签字节必须不同。
  assert.ok(
    !withContext(CONTEXT_TAG_CATALOG, body).equals(tagged),
    "同一正文在不同域下的待签字节必须不同（否则可跨协议重放）",
  );
  console.log("✓ 签名域分隔（tag ‖ 0x00 ‖ bytes，三域互不为前缀、不可互换）");
}

// ---- payload 序列化键序稳定 ----

{
  const a = serializePayload({
    adapterId: "school-x",
    adapterVersion: "1.0.0",
    tier: "official",
    digest: "ab",
  });
  const b = serializePayload({
    digest: "ab",
    tier: "official",
    adapterVersion: "1.0.0",
    adapterId: "school-x",
  } as never);
  assert.ok(a.equals(b), "payload 序列化须与输入键序无关（固定键序）");
  // 载荷已带域分隔前缀（digest v2）：验端若忘了加前缀就验不过——这里钉死它确实在。
  assert.ok(
    a.subarray(0, CONTEXT_TAG_BUNDLE.length).toString("utf-8") === CONTEXT_TAG_BUNDLE,
    "serializePayload 产物须以 elecon.bundle-payload/2 域分隔前缀开头",
  );
  console.log("✓ payload 序列化键序稳定 + 带 bundle 域分隔前缀");
}

// ---- semver 比较 ----

{
  assert.strictEqual(compareSemver("1.2.0", "1.10.0"), -1, "1.2.0 < 1.10.0（数字非字典序）");
  assert.strictEqual(compareSemver("2.0.0", "1.9.9"), 1);
  assert.strictEqual(compareSemver("1.0.0", "1.0.0"), 0);
  // 评审 #2：超大版本号不得丢精度（Number 会在 2^53 以上把不同值当相等）。
  const huge = "99999999999999999999";
  assert.strictEqual(compareSemver(`${huge}.0.0`, "1.0.0"), 1, "超大版本号 > 1.0.0（不溢出）");
  assert.strictEqual(compareSemver(`${huge}.0.0`, `${huge}.0.0`), 0, "超大版本号自比相等");
  assert.strictEqual(compareSemver("1.02.0", "1.2.0"), 0, "前导零不影响数值序");
  console.log("✓ semver 比较（含无界大版本号）");
}

// ---- revocation 判定 ----

const base: RevocationList = {
  sequence: 5,
  issuedAt: "2026-07-09T00:00:00Z",
  ttlSeconds: 3600,
  minVersions: {},
  killSwitch: false,
  entries: [],
};

{
  // kill-switch
  const d = isRevoked(
    { adapterId: "school-x", adapterVersion: "1.0.0", digest: "aa" },
    { ...base, killSwitch: true },
  );
  assert.ok(!d.allowed && /kill-switch/.test(d.reason ?? ""), "kill-switch 应拒绝一切");

  // 最低版本
  const d2 = isRevoked(
    { adapterId: "school-x", adapterVersion: "1.0.0", digest: "aa" },
    { ...base, minVersions: { "school-x": "1.2.0" } },
  );
  assert.ok(!d2.allowed && /低于最低/.test(d2.reason ?? ""), "低于最低版本应拒绝");

  // digest 精确吊销
  const d3 = isRevoked(
    { adapterId: "school-x", adapterVersion: "1.0.0", digest: "deadbeef" },
    { ...base, entries: [{ adapterId: "school-x", digest: "deadbeef", reason: "有漏洞" }] },
  );
  assert.ok(!d3.allowed && /被吊销/.test(d3.reason ?? ""), "digest 命中应拒绝");

  // 版本区间吊销
  const d4 = isRevoked(
    { adapterId: "school-x", adapterVersion: "1.1.0", digest: "aa" },
    {
      ...base,
      entries: [
        {
          adapterId: "school-x",
          versionRange: { minInclusive: "1.0.0", maxInclusive: "1.2.0" },
          reason: "区间坏",
        },
      ],
    },
  );
  assert.ok(!d4.allowed && /区间/.test(d4.reason ?? ""), "版本区间命中应拒绝");

  // 放行（无命中）
  const d5 = isRevoked({ adapterId: "school-y", adapterVersion: "3.0.0", digest: "aa" }, base);
  assert.ok(d5.allowed, "无命中应放行");

  console.log("✓ revocation 判定（kill-switch / 最低版本 / digest / 区间 / 放行）");
}

// ---- 防回滚 ----

{
  const older: RevocationList = { ...base, sequence: 3 };
  const newer: RevocationList = { ...base, sequence: 7 };
  assert.strictEqual(pickNewer(newer, older).sequence, 7, "旧序号不得覆盖新序号");
  assert.strictEqual(pickNewer(base, newer).sequence, 7, "新序号应被采用");
  console.log("✓ 防回滚（sequence 单调）");
}

// ---- 签发侧拒反向区间（评审 #3） ----

{
  const noopBackend = {
    keyId: "smoke",
    async sign() {
      return "";
    },
  };
  const bad: RevocationList = {
    ...base,
    entries: [
      {
        adapterId: "school-x",
        versionRange: { minInclusive: "2.0.0", maxInclusive: "1.0.0" },
        reason: "反向区间",
      },
    ],
  };
  await assert.rejects(
    () => signRevocation(bad, noopBackend),
    /下界 2\.0\.0 > 上界 1\.0\.0/,
    "签发侧应拒绝反向版本区间（空区间静默失效）",
  );
  console.log("✓ 签发侧拒反向版本区间");
}

console.log("\nsigner smoke（确定性部分）全部通过 ✅  —— sign/verify 往返测试留待人工闭环。");
