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
import { fileURLToPath } from "node:url";

import {
  assembleRequest,
  processResponse,
  type AssembleRequestInput,
  type AssembleResult,
  type ProcessedResponse,
  type RawResponse,
} from "./assemble.js";
import { CookieJar } from "./cookie-jar.js";
import type { BrokerManifestView } from "./inject-policy.js";
import type { CredentialResolver, ResolvedCredential } from "./ports.js";
import {
  proxyFetch,
  BrokerFetchRejected,
  type Transport,
  type TransportRequest,
  type TransportResponse,
} from "./fetch-proxy.js";

const repoRoot = fileURLToPath(new URL("../../../../", import.meta.url));
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

/** fake resolver：按 ref→ResolvedCredential 映射；未命中返回 null。 */
class FakeResolver implements CredentialResolver {
  constructor(private readonly map: Record<string, ResolvedCredential>) {}
  async get(ref: string): Promise<ResolvedCredential | null> {
    return this.map[ref] ?? null;
  }
}

/** fake transport：按队列回放响应，并记录每次收到的请求（供断言 Cookie/Authorization）。 */
class FakeTransport implements Transport {
  readonly seen: TransportRequest[] = [];
  constructor(private readonly queue: TransportResponse[]) {}
  async fetch(req: TransportRequest): Promise<TransportResponse> {
    this.seen.push(req);
    const resp = this.queue.shift();
    if (!resp) throw new Error("FakeTransport 队列耗尽");
    return resp;
  }
}

function resp(partial: Partial<TransportResponse> & { status: number }): TransportResponse {
  return { headers: {}, setCookie: [], location: null, ...partial };
}

async function driverTests(): Promise<number> {
  let checks = 0;

  // 1. fail-closed：url 不在 allow → 抛 BrokerFetchRejected，绝不发请求。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/api/*"] };
    const transport = new FakeTransport([]);
    await assert.rejects(
      proxyFetch("https://evil.example.com/x", {}, {
        view,
        resolver: new FakeResolver({}),
        jar: new CookieJar(),
        transport,
      }),
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
      resp({ status: 200, headers: { "Content-Type": "application/json", "Set-Cookie": "leak=1" }, setCookie: ["leak=1"], body: "{}" }),
    ]);
    const out = await proxyFetch("https://h.edu.cn/api/grades", {}, {
      view,
      resolver: new FakeResolver({ session: { via: "cookie", value: "JSESSIONID=S1" } }),
      jar: new CookieJar(),
      transport,
    });
    assert.equal(transport.seen[0]!.headers["Cookie"], "JSESSIONID=S1", "broker 注入 cookie 应出现在出站请求");
    assert.equal(out.headers["Set-Cookie"], undefined, "响应 Set-Cookie 不得回交 adapter");
    assert.equal(out.status, 200);
    assert.equal(out.requestCount, 1);
    checks++;
  }

  // 3. 重定向链：hop1 302 → hop2 200（均在 allow）；逐跳捕获 Set-Cookie；中间 Location 不外泄；requestCount=2。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
    const transport = new FakeTransport([
      resp({ status: 302, location: "https://h.edu.cn/step2", setCookie: ["hop1=a"] }),
      resp({ status: 200, headers: { "Content-Type": "text/html", "Location": "https://h.edu.cn/leak?t=x" }, setCookie: ["hop2=b"], body: "ok" }),
    ]);
    const out = await proxyFetch("https://h.edu.cn/step1", {}, {
      view,
      resolver: new FakeResolver({}),
      jar: new CookieJar(),
      transport,
    });
    assert.equal(out.status, 200);
    assert.equal(out.requestCount, 2, "每跳各计一次请求（计划 §8 #3）");
    assert.equal(out.headers["Location"], undefined, "最终响应 Location（含 token）不得外泄");
    // hop1 捕获的 Set-Cookie 应在 hop2 的出站请求携带（jar 跨跳搬运）。
    assert.equal(transport.seen[1]!.headers["Cookie"], "hop1=a", "hop1 Set-Cookie 应在 hop2 携带");
    checks++;
  }

  // 4. 重定向越出 allow → stop，交付当前响应（其 Location 被脱敏剥除），不再续跳。
  {
    const view: BrokerManifestView = { allow: ["https://h.edu.cn/*"] };
    const transport = new FakeTransport([
      resp({ status: 302, location: "https://evil.example.com/grab?t=secret", headers: { "Location": "https://evil.example.com/grab?t=secret" } }),
    ]);
    const out = await proxyFetch("https://h.edu.cn/start", {}, {
      view,
      resolver: new FakeResolver({}),
      jar: new CookieJar(),
      transport,
    });
    assert.equal(out.status, 302);
    assert.equal(out.requestCount, 1, "越界跳不发出");
    assert.equal(out.headers["Location"], undefined, "越界 Location 不得外泄");
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
    await proxyFetch("https://dean.xjtu.edu.cn/list", {}, {
      view,
      resolver: new FakeResolver({}),
      jar,
      transport,
    });
    assert.equal(transport.seen[0]!.headers["Cookie"], "client_id=abc", "ephemeral cookie 应在 passthrough 出站携带");
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

  return checks;
}

async function main(): Promise<void> {
  const g = goldenTests();
  const d = await driverTests();
  console.log(
    `broker B6a assemble smoke: golden assemble ${g.assemble}/${g.assemble} + process ${g.process}/${g.process} + driver ${d}/${d} 例通过 ✅`,
  );
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
