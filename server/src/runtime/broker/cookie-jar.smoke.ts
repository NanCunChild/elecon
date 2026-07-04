/**
 * Broker B4 cookie jar 冒烟测试 —— golden 驱动纯决策 + 有态 jar 行为。
 *
 *   contract/golden/broker/cookie-jar.json
 *     → decideEphemeralWrite / matchCookieForSend / selectCookies  逐例等于 expected
 *   CookieJar（有态）
 *     → 捕获缺省 domain/path、显式属性、跨跳累计+轮换、ephemeral 写回/拒绝、分区隔离
 *
 *   运行：cd server && npm run smoke:cookie
 *
 * 🔒 红线 #1 写入面（adapter→jar）+ 会话态匹配：与被测代码一并须人工 + 安全清单复核
 * （不得 AI 独自闭环，AGENTS.md §1）。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { resolveRepoRoot, runMain } from "../__testutils__/smoke-utils.js";

import {
  CookieJar,
  decideEphemeralWrite,
  matchCookieForSend,
  selectCookies,
  type EphemeralWriteDecision,
  type EphemeralWriteInput,
  type JarCookie,
} from "./cookie-jar.js";
import type { BrokerManifestView } from "./inject-policy.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const goldenPath = `${repoRoot}contract/golden/broker/cookie-jar.json`;

interface Golden {
  decideEphemeralWrite: Array<{
    name: string;
    input: { opts: EphemeralWriteInput; view: BrokerManifestView };
    expected: EphemeralWriteDecision;
  }>;
  matchCookieForSend: Array<{
    name: string;
    input: { cookie: { domain: string; path: string }; requestUrl: string };
    expected: boolean;
  }>;
  selectCookies: Array<{
    name: string;
    input: { cookies: JarCookie[]; requestUrl: string };
    expected: Array<{ name: string; value: string }>;
  }>;
}

function goldenTests(): number {
  const g = JSON.parse(readFileSync(goldenPath, "utf8")) as Golden;
  let n = 0;
  for (const c of g.decideEphemeralWrite) {
    assert.deepStrictEqual(
      decideEphemeralWrite(c.input.opts, c.input.view),
      c.expected,
      `decideEphemeralWrite '${c.name}'`,
    );
    n++;
  }
  for (const c of g.matchCookieForSend) {
    assert.equal(
      matchCookieForSend(c.input.cookie, c.input.requestUrl),
      c.expected,
      `matchCookieForSend '${c.name}'`,
    );
    n++;
  }
  for (const c of g.selectCookies) {
    assert.deepStrictEqual(
      selectCookies(c.input.cookies, c.input.requestUrl),
      c.expected,
      `selectCookies '${c.name}'`,
    );
    n++;
  }
  assert.ok(n > 0, "golden 向量为空");
  return n;
}

function statefulTests(): number {
  const view: BrokerManifestView = {
    allow: ["https://dean.xjtu.edu.cn/*", "https://ids.xjtu.edu.cn/*"],
    credentials: { sess: { scope: ["https://ids.xjtu.edu.cn/*"], type: "cookie" } },
  };
  const warns: string[] = [];
  const warn = (m: string): void => void warns.push(m);
  let checks = 0;

  // 1. 捕获缺省 domain/path（RFC 6265 §5.3：host-only domain + default-path）
  const jar = new CookieJar();
  jar.captureSetCookie(["sid=abc"], "https://dean.xjtu.edu.cn/a/b");
  assert.deepStrictEqual(jar.harvestView(), [
    { name: "sid", value: "abc", domain: "dean.xjtu.edu.cn", path: "/a", source: "origin" },
  ]);
  assert.equal(jar.cookieHeader("https://dean.xjtu.edu.cn/a/x"), "sid=abc");
  assert.equal(jar.cookieHeader("https://dean.xjtu.edu.cn/other"), ""); // path /a 不匹配 /other
  checks++;

  // 2. 显式 Domain/Path 属性（前导点归一为 host-only）；父域合法（dean.xjtu ⊆ xjtu）
  const jar2 = new CookieJar();
  jar2.captureSetCookie(["sess=xyz; Domain=.xjtu.edu.cn; Path=/"], "https://dean.xjtu.edu.cn/login");
  assert.deepStrictEqual(jar2.harvestView(), [
    { name: "sess", value: "xyz", domain: "xjtu.edu.cn", path: "/", source: "origin" },
  ]);
  checks++;

  // 2b. 非法 Domain（#79 P0-4，RFC 6265 §5.3 step 6）：响应 host 不 domain-match 声明的
  //     Domain → 整条 Set-Cookie 丢弃（fail-closed），封堵 allow 集内跨域伪造。
  const jarBad = new CookieJar();
  // 完全无关的域
  jarBad.captureSetCookie(["evil=1; Domain=other.edu.cn"], "https://dean.xjtu.edu.cn/x");
  // 子域伪造父域方向（响应 host 是被声明域的父域，不 domain-match）
  jarBad.captureSetCookie(["evil2=1; Domain=sub.dean.xjtu.edu.cn"], "https://dean.xjtu.edu.cn/x");
  // 过宽父域 / public suffix 类 Domain：会污染其他 *.edu.cn host
  jarBad.captureSetCookie(["evil3=1; Domain=edu.cn"], "https://dean.xjtu.edu.cn/x");
  assert.deepStrictEqual(jarBad.harvestView(), [], "非法 Domain 的 Set-Cookie 必须整条丢弃");
  assert.equal(jarBad.cookieHeader("https://other.edu.cn/x"), "", "伪造 cookie 不得发往他域");
  checks++;

  // 3. 跨跳累计 + 同 (name,domain,path) 轮换覆盖（会话轮换以最新为准）
  const jar3 = new CookieJar();
  jar3.captureSetCookie(["a=1"], "https://dean.xjtu.edu.cn/");
  jar3.captureSetCookie(["b=2"], "https://dean.xjtu.edu.cn/");
  jar3.captureSetCookie(["a=ROTATED"], "https://dean.xjtu.edu.cn/");
  assert.equal(jar3.harvestView().length, 2);
  assert.equal(jar3.cookieHeader("https://dean.xjtu.edu.cn/"), "a=ROTATED; b=2");
  checks++;

  // 4. ephemeral 接受（passthrough），但同名让位 origin（栅栏 2）；ephemeral 不进收割（栅栏 3）
  const jar4 = new CookieJar();
  jar4.captureSetCookie(["client_id=ORIGIN"], "https://dean.xjtu.edu.cn/");
  assert.equal(
    jar4.writeEphemeral({ name: "client_id", value: "EPH", domain: "dean.xjtu.edu.cn" }, view, warn),
    true,
  );
  assert.equal(jar4.cookieHeader("https://dean.xjtu.edu.cn/"), "client_id=ORIGIN");
  assert.equal(jar4.harvestView().length, 1);
  assert.ok(jar4.harvestView().every((c) => c.source === "origin"), "收割视图只含 origin");
  checks++;

  // 5. ephemeral 被拒（凭证域）→ 静默丢弃 + warn（栅栏 1.2，拍板 #3：不抛错）
  const jar5 = new CookieJar();
  assert.equal(
    jar5.writeEphemeral({ name: "x", value: "v", domain: "ids.xjtu.edu.cn" }, view, warn),
    false,
  );
  assert.equal(jar5.cookieHeader("https://ids.xjtu.edu.cn/"), "");
  assert.equal(jar5.harvestView().length, 0);
  assert.ok(warns.some((w) => w.includes("domain_is_credential")), "拒绝须 warn 且标明原因");
  checks++;

  // 6. ephemeral-only 在无 origin 同名时生效，且仍不收割
  const jar6 = new CookieJar();
  assert.equal(
    jar6.writeEphemeral({ name: "client_id", value: "EPH", domain: "dean.xjtu.edu.cn" }, view, warn),
    true,
  );
  assert.equal(jar6.cookieHeader("https://dean.xjtu.edu.cn/"), "client_id=EPH");
  assert.equal(jar6.harvestView().length, 0);
  checks++;

  return checks;
}

function main(): void {
  const g = goldenTests();
  const s = statefulTests();
  console.log(`broker B4 cookie-jar smoke: golden ${g}/${g} + stateful ${s}/${s} 例通过 ✅`);
}

runMain(main);
