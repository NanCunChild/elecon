/**
 * Broker B6a 拼装管线冒烟测试 —— golden 驱动 assembleRequest/processResponse + fake-transport 驱动 proxyFetch。
 *
 *   contract/golden/broker/assemble.json  →  assembleRequest / processResponse  →  逐例等于 expected
 *   proxyFetch + FakeTransport + FakeResolver + 真 CookieJar  →  端到端：fail-closed / 重定向链 /
 *     逐跳捕获 Set-Cookie / 跨跳携带 cookie / 中间 Location 不外泄 / requestCount 计量
 *
 *   运行：cd server && npm run smoke:assemble
 *
 * golden 段由客户端（Dart, B6c）照样跑（两端双跑，ADR-001 §8）。驱动段触 async/transport，
 * 不可纯 golden 化，沿 harvest.smoke 集成范式用 fake 驱动（计划 §2）。
 *
 * 🔒 红线 #1 凭证注入 + 出网承重路径：与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
 */

import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { FakeResolver, FakeTransport, resolveRepoRoot, resp, runMain } from "../__testutils__/smoke-utils.js";

import {
  type AssembleRequestInput,
  type AssembleResult,
  assembleRequest,
  type ProcessedResponse,
  processResponse,
  type RawResponse,
} from "./assemble.js";
import { CookieJar } from "./cookie-jar.js";
import { BrokerFetchRejected, proxyFetch } from "./fetch-proxy.js";
import type { BrokerManifestView } from "./inject-policy.js";

const repoRoot = resolveRepoRoot(import.meta.url);
const goldenPath = `${repoRoot}contract/golden/broker/assemble.json`;

interface GoldenFile {
  assemble: Array<{ name: string; input: AssembleRequestInput; expected: AssembleResult }>;
  process: Array<{ name: string; input: RawResponse; expected: ProcessedResponse }>;
}

function goldenTests(): { assemble: number; process: number } {
  const golden = JSON.parse(readFileSync(goldenPath, "utf8")) as GoldenFile;
  assert.ok(golden.assemble.length > 0 && golden.process.length > 0, "golden 向量为空");

  for (const c of golden.assemble) {
    const actual = assembleRequest(c.input);
    assert.deepStrictEqual(
      actual,
      c.expected,
      `assemble '${c.name}'\n  期望 ${JSON.stringify(c.expected)}\n  实得 ${JSON.stringify(actual)}`,
    );
  }
  for (const c of golden.process) {
    const actual = processResponse(c.input);
    assert.deepStrictEqual(
      actual,
      c.expected,
      `process '${c.name}'\n  期望 ${JSON.stringify(c.expected)}\n  实得 ${JSON.stringify(actual)}`,
    );
  }
  return { assemble: golden.assemble.length, process: golden.process.length };
}

async function driverTests(): Promise<number> {
  let checks = 0;

  // 1. fail-closed：url 不在 allow → 抛 BrokerFetchRejected，绝不发请求。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/api/*"] };
    const transport = new FakeTransport([]);
    await assert.rejects(
      proxyFetch(
        "https://evil.example.com/x",
        {},
        {
          view,
          resolver: new FakeResolver({}),
          jar: new CookieJar(),
          transport,
        },
      ),
      (e: unknown) => e instanceof BrokerFetchRejected && e.reason === "outside_allow",
    );
    assert.equal(transport.seen.length, 0, "拒绝时不得发任何请求");
    checks++;
  }

  // 2. inject cookie 端到端：transport 收到 broker 注入的 Cookie；响应 Set-Cookie 被脱敏剥除。
  {
    const view: BrokerManifestView = {
      allow: ["https://h.edu.cn/api/*"],
      credentials: { session: { scope: ["https://h.edu.cn/api/*"], type: "cookie" } },
    };
    const transport = new FakeTransport([
      resp({
        status: 200,
        headers: { "Content-Type": "application/json", "Set-Cookie": "leak=1" },
        setCookie: ["leak=1"],
        body: "{}",
      }),
    ]);
    const out = await proxyFetch(
      "https://h.edu.cn/api/grades",
      {},
      {
        view,
        resolver: new FakeResolver({ session: { via: "cookie", value: "JSESSIONID=S1" } }),
        jar: new CookieJar(),
        transport,
      },
    );
    assert.equal(
      transport.seen[0]!.headers["Cookie"],
      "JSESSIONID=S1",
      "broker 注入 cookie 应出现在出站请求",
    );
    assert.equal(out.headers["Set-Cookie"], undefined, "响应 Set-Cookie 不得回交 adapter");
    assert.equal(out.status, 200);
    assert.equal(out.requestCount, 1);
    checks++;
  }

  // 2b. query credential：覆盖 adapter 伪值、保留其他参数，且不写 Cookie/Authorization。
  {
    const credentialValue = "opaque+student/id";
    const view: BrokerManifestView = {
      allow: ["https://card.h.edu.cn/*"],
      credentials: {
        session: {
          scope: ["https://card.h.edu.cn/*"],
          type: "query",
          queryParam: "openid",
        },
      },
    };
    const transport = new FakeTransport([resp({ status: 200, body: "{}" })]);
    await proxyFetch(
      "https://card.h.edu.cn/account?keep=1&openid=attacker&openid=duplicate#fragment",
      { headers: { Cookie: "attacker=1", Authorization: "Bearer attacker" } },
      {
        view,
        resolver: new FakeResolver({ session: { via: "query", value: credentialValue } }),
        jar: new CookieJar(),
        transport,
      },
    );
    const sent = transport.seen[0]!;
    assert.equal(
      sent.url,
      "https://card.h.edu.cn/account?keep=1&openid=opaque%2Bstudent%2Fid#fragment",
      "query credential 应覆盖全部同名伪值并正确编码",
    );
    assert.equal(sent.headers.Cookie, undefined, "query credential 不得写入 Cookie");
    assert.equal(sent.headers.Authorization, undefined, "query credential 不得写入 Authorization");
    checks++;
  }

  // 3. 重定向链：hop1 302 → hop2 200（均在 allow）；逐跳捕获 Set-Cookie；中间 Location 不外泄；requestCount=2。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
    const transport = new FakeTransport([
      resp({ status: 302, location: "https://h.edu.cn/step2", setCookie: ["hop1=a"] }),
      resp({
        status: 200,
        headers: { "Content-Type": "text/html", Location: "https://h.edu.cn/leak?t=x" },
        setCookie: ["hop2=b"],
        body: "ok",
      }),
    ]);
    const out = await proxyFetch(
      "https://h.edu.cn/step1",
      {},
      {
        view,
        resolver: new FakeResolver({}),
        jar: new CookieJar(),
        transport,
      },
    );
    assert.equal(out.status, 200);
    assert.equal(out.requestCount, 2, "每跳各计一次请求（计划 §8 #3）");
    assert.equal(out.headers["Location"], undefined, "最终响应 Location（含 token）不得外泄");
    // hop1 捕获的 Set-Cookie 应在 hop2 的出站请求携带（jar 跨跳搬运）。
    assert.equal(transport.seen[1]!.headers["Cookie"], "hop1=a", "hop1 Set-Cookie 应在 hop2 携带");
    checks++;
  }

  // 3b. host-only 不跨子域；显式 Domain 保留 domain 语义。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*", "https://sub.h.edu.cn/*"] };
    const transport = new FakeTransport([
      resp({
        status: 302,
        location: "https://sub.h.edu.cn/step2",
        setCookie: ["host=H; Path=/", "domain=D; Domain=h.edu.cn; Path=/"],
      }),
      resp({ status: 200, body: "ok" }),
    ]);
    await proxyFetch(
      "https://h.edu.cn/step1",
      {},
      {
        view,
        resolver: new FakeResolver({}),
        jar: new CookieJar(),
        transport,
      },
    );
    assert.equal(
      transport.seen[1]!.headers.Cookie,
      "domain=D",
      "无 Domain cookie 不得随重定向发往子域；显式 Domain 须保留 domain 语义",
    );
    checks++;
  }

  // 4. 重定向越出 allow → blocked：poison body/ETag/Set-Cookie/query token 全部不可见且零副作用。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
    const jar = new CookieJar();
    const harvested: string[] = [];
    const transport = new FakeTransport([
      resp({
        status: 302,
        location: "https://evil.example.com/grab?ticket=opaque",
        headers: { Location: "https://evil.example.com/grab?ticket=opaque", ETag: "visible-if-delivered" },
        setCookie: ["blocked=must-not-stick; Path=/"],
        body: "{poison-not-json",
      }),
    ]);
    await assert.rejects(
      proxyFetch(
        "https://h.edu.cn/start",
        {},
        {
          view,
          resolver: new FakeResolver({}),
          jar,
          transport,
          queryHarvest: {
            view: {
              allow: ["https://evil.example.com/*"],
              credentials: {
                ticket: {
                  scope: ["https://evil.example.com/*"],
                  type: "query",
                  queryParam: "ticket",
                },
              },
            },
            sink: { put: (entry) => harvested.push(entry.value) },
            schoolId: "school",
            now: () => 1,
          },
          // 若误入 firewall，此 malformed poison body 会触发 MaskerError。
          masker: {
            policy: {
              schemaVersion: 1,
              rules: [
                {
                  id: "poison-guard",
                  match: { capability: "notice.list", method: "GET", urlScope: "https://evil.example.com/*" },
                  capture: { source: "json", path: "$.token", destination: { kind: "redact" } },
                  project: "delete",
                },
              ],
            },
            capability: "notice.list",
            sink: { put() {} },
            ctx: { schoolId: "school", now: () => 1 },
          },
        },
      ),
      (e: unknown) => e instanceof BrokerFetchRejected && e.reason === "redirect_outside_allow",
    );
    assert.equal(transport.seen.length, 1, "越界跳不发出");
    assert.deepStrictEqual(jar.selectForSend("https://h.edu.cn/next"), [], "blocked Set-Cookie 不得入 jar");
    assert.deepStrictEqual(harvested, [], "blocked Location query 不得收割");
    checks++;
  }

  // 4a. max hops 同样是不可交付的安全拒绝，不是可交付 302。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
    await assert.rejects(
      proxyFetch(
        "https://h.edu.cn/start",
        {},
        {
          view,
          resolver: new FakeResolver({}),
          jar: new CookieJar(),
          transport: new FakeTransport([
            resp({ status: 302, location: "https://h.edu.cn/next", body: "poison" }),
          ]),
          maxHops: 0,
        },
      ),
      (e: unknown) => e instanceof BrokerFetchRejected && e.reason === "redirect_max_hops",
    );
    checks++;
  }

  // 4b. 核心只收割已通过 allow、确定跟随的 query credential 重定向目标。
  {
    const injectView: BrokerManifestView = {
      allow: ["https://ids.h.edu.cn/*", "https://card.h.edu.cn/*"],
    };
    const harvestView: BrokerManifestView = {
      allow: injectView.allow,
      credentials: {
        card: {
          scope: ["https://card.h.edu.cn/*"],
          type: "query",
          queryParam: "openid",
        },
      },
    };
    const entries: Array<{ ref: string; value: string }> = [];
    const transport = new FakeTransport([
      resp({ status: 302, location: "https://card.h.edu.cn/home?openid=opaque" }),
      resp({ status: 200, body: "ok" }),
    ]);
    await proxyFetch(
      "https://ids.h.edu.cn/login",
      {},
      {
        view: injectView,
        resolver: new FakeResolver({}),
        jar: new CookieJar(),
        transport,
        queryHarvest: {
          view: harvestView,
          sink: { put: (entry) => entries.push({ ref: entry.ref, value: entry.value }) },
          schoolId: "school",
          now: () => 1,
        },
      },
    );
    assert.deepStrictEqual(entries, [{ ref: "card", value: "opaque" }]);
    checks++;
  }

  // 4c. 302 无 Location 是正常 terminal deliver，仍捕获 Set-Cookie 并经 firewall 交付。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
    const jar = new CookieJar();
    const out = await proxyFetch(
      "https://h.edu.cn/terminal",
      {},
      {
        view,
        resolver: new FakeResolver({}),
        jar,
        transport: new FakeTransport([
          resp({
            status: 302,
            headers: { ETag: "terminal-etag" },
            setCookie: ["terminal=kept; Path=/"],
            body: "terminal-body",
          }),
        ]),
      },
    );
    assert.equal(out.status, 302);
    assert.equal(out.headers.ETag, "terminal-etag");
    assert.equal(out.body, "terminal-body");
    assert.equal(jar.selectForSend("https://h.edu.cn/next")[0]?.name, "terminal");
    checks++;
  }

  // 5. passthrough origin：ephemeral cookie（XJT body-token 缺口）经 jar 写入后在出站携带。
  {
    const view: BrokerManifestView = { allow: ["https://dean.xjtu.edu.cn/*"] };
    const jar = new CookieJar();
    const warnings: string[] = [];
    const ok = jar.writeEphemeral(
      { name: "client_id", value: "abc", domain: "dean.xjtu.edu.cn" },
      view,
      (m) => warnings.push(m),
    );
    assert.ok(ok && warnings.length === 0, "passthrough origin 的 ephemeral 写入应被接受");
    const transport = new FakeTransport([resp({ status: 200, body: "[]" })]);
    await proxyFetch(
      "https://dean.xjtu.edu.cn/list",
      {},
      {
        view,
        resolver: new FakeResolver({}),
        jar,
        transport,
      },
    );
    assert.equal(
      transport.seen[0]!.headers["Cookie"],
      "client_id=abc",
      "ephemeral cookie 应在 passthrough 出站携带",
    );
    checks++;
  }

  // 6. adapter 自设 Cookie/Authorization 在出站被无条件剥除（纵深防御，红线 #1）。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
    const transport = new FakeTransport([resp({ status: 200 })]);
    await proxyFetch(
      "https://h.edu.cn/x",
      { headers: { Cookie: "forged=1", Authorization: "Bearer forged", Accept: "*/*" } },
      { view, resolver: new FakeResolver({}), jar: new CookieJar(), transport },
    );
    const sent = transport.seen[0]!.headers;
    assert.equal(sent["Cookie"], undefined, "adapter 自设 Cookie 必须剥除");
    assert.equal(sent["Authorization"], undefined, "adapter 自设 Authorization 必须剥除");
    assert.equal(sent["Accept"], "*/*", "allowlist 头保留");
    checks++;
  }

  // 7. transport 晚到 302：取消检查先于 cookie/query/firewall，且不得发下一跳。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
    const jar = new CookieJar();
    const harvested: string[] = [];
    const controller = new AbortController();
    let release!: (response: ReturnType<typeof resp>) => void;
    const seen: unknown[] = [];
    const transport = {
      fetch(req: unknown) {
        seen.push(req);
        return new Promise<ReturnType<typeof resp>>((resolve) => {
          release = resolve;
        });
      },
    };
    const pending = proxyFetch(
      "https://h.edu.cn/start",
      {},
      {
        view,
        resolver: new FakeResolver({}),
        jar,
        transport,
        signal: controller.signal,
        queryHarvest: {
          view: {
            allow: view.allow,
            credentials: {
              ticket: { scope: view.allow, type: "query", queryParam: "ticket" },
            },
          },
          sink: { put: (entry) => harvested.push(entry.value) },
          schoolId: "school",
          now: () => 1,
        },
      },
    );
    controller.abort();
    release(
      resp({
        status: 302,
        location: "https://h.edu.cn/next?ticket=late",
        headers: { ETag: "late-visible" },
        setCookie: ["late=must-not-stick; Path=/"],
        body: "late-poison",
      }),
    );
    await assert.rejects(
      pending,
      (e: unknown) => e instanceof BrokerFetchRejected && e.reason === "cancelled",
    );
    assert.equal(seen.length, 1, "取消后的晚到 302 不得发下一跳");
    assert.deepStrictEqual(jar.selectForSend("https://h.edu.cn/next"), [], "晚到 Set-Cookie 不得入 jar");
    assert.deepStrictEqual(harvested, [], "晚到 Location query 不得收割");
    checks++;
  }

  return checks;
}

async function main(): Promise<void> {
  const g = goldenTests();
  const d = await driverTests();
  console.log(
    `broker B6a assemble smoke: golden assemble ${g.assemble}/${g.assemble} + process ${g.process}/${g.process} + driver ${d}/${d} 例通过 ✅`,
  );
}

runMain(main);
