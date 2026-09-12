/**
 * `direct` 档传输冒烟测试（Gate A · ADR-003 §2.2，服务端）—— 对本地 node:http server 验证
 * DirectTransport 正确映射请求/响应、暴露原始 Set-Cookie/Location、**不自动跟随重定向**（单跳）。
 * 与客户端 `transport_direct_test.dart` 对称。
 *
 *   运行：cd server && npm run smoke:transport
 *
 * 🔒 transport 承载注入凭证的真实请求（红线 #1 路径）：与被测代码一并须人工 + 安全清单复核。
 */

import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { noResolver, runMain } from "../__testutils__/smoke-utils.js";
import { CookieJar } from "../broker/cookie-jar.js";
import { DeliveryFirewallError } from "../broker/delivery-firewall.js";
import { proxyFetch, TransportBodyLimitExceeded } from "../broker/fetch-proxy.js";
import type { BrokerManifestView } from "../broker/inject-policy.js";
import { CredentialStore } from "../credential/store.js";
import { DirectTransport } from "./direct.js";

async function main(): Promise<void> {
  let base = "";
  const server = createServer((reqMsg, res) => {
    if (reqMsg.url === "/echo") {
      let body = "";
      reqMsg.on("data", (c) => (body += c));
      reqMsg.on("end", () => {
        res.statusCode = 200;
        res.setHeader("content-type", "application/json");
        res.setHeader("set-cookie", ["a=1", "b=2"]); // 多条 Set-Cookie
        res.end(
          JSON.stringify({
            method: reqMsg.method,
            gotCookie: reqMsg.headers.cookie ?? null,
            gotAuth: reqMsg.headers.authorization ?? null,
            body,
          }),
        );
      });
    } else if (reqMsg.url === "/redirect") {
      res.statusCode = 302;
      res.setHeader("location", `${base}/echo`);
      res.end();
    } else if (reqMsg.url === "/big") {
      res.statusCode = 200;
      res.setHeader("content-type", "text/plain");
      res.end("0123456789");
    } else if (reqMsg.url === "/dup-token-header") {
      // P1-04：线上真的发两个同名 token 头。WHATWG Headers 会把它折叠成 "A, B"。
      res.statusCode = 200;
      res.setHeader("content-type", "application/json");
      res.setHeader("x-session-secret", ["TOK_A_FICTITIOUS", "TOK_B_FICTITIOUS"]);
      res.end(JSON.stringify({ ok: true }));
    } else if (reqMsg.url === "/gbk") {
      // 声明非 UTF-8 charset：A3 不猜测转码 → decodeOk=false。
      res.statusCode = 200;
      res.setHeader("content-type", "text/html; charset=gbk");
      res.end("<html>ok</html>");
    } else if (reqMsg.url === "/badutf8") {
      // 声明（默认）UTF-8 但字节非法 UTF-8（孤立续字节 0x80 / 0xFF）→ decodeOk=false。
      res.statusCode = 200;
      res.setHeader("content-type", "application/json");
      res.end(Buffer.from([0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xff, 0x80, 0x22, 0x7d]));
    } else {
      res.statusCode = 404;
      res.end();
    }
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const transport = new DirectTransport();
  let checks = 0;

  try {
    // 1. GET 映射 + 响应字段 + 多条 Set-Cookie 单独暴露
    {
      const resp = await transport.fetch({
        url: `${base}/echo`,
        method: "GET",
        headers: { Cookie: "JSESSIONID=S1", Authorization: "Bearer T" },
      });
      assert.equal(resp.status, 200);
      const b = JSON.parse(resp.body!) as Record<string, unknown>;
      assert.equal(b.method, "GET");
      assert.equal(b.gotCookie, "JSESSIONID=S1", "broker 注入的 Cookie 头应出站");
      assert.equal(b.gotAuth, "Bearer T");
      assert.deepEqual(resp.setCookie, ["a=1", "b=2"], "原始 Set-Cookie 多条单独交回");
      assert.equal(resp.headers["set-cookie"], undefined, "Set-Cookie 不并入普通响应头");
      assert.ok(resp.headers["content-type"]?.includes("application/json"));
      checks++;
    }

    // 2. POST 携带 body
    {
      const resp = await transport.fetch({
        url: `${base}/echo`,
        method: "POST",
        headers: { "Content-Type": "text/plain" },
        body: "hello-body",
      });
      const b = JSON.parse(resp.body!) as Record<string, unknown>;
      assert.equal(b.method, "POST");
      assert.equal(b.body, "hello-body");
      checks++;
    }

    // 3. 重定向不自动跟随（单跳）→ 302 + Location 交回核心
    {
      const resp = await transport.fetch({
        url: `${base}/redirect`,
        method: "GET",
        headers: {},
      });
      assert.equal(resp.status, 302, "不跟随 → 返回 302 本身（跟随了会是 200）");
      assert.equal(resp.location, `${base}/echo`, "Location 暴露给核心（B3 跟随）");
      assert.equal(resp.body, "", "未自动抓取 /echo");
      checks++;
    }

    // 4. 端到端真网络：proxyFetch over DirectTransport（B3 跟随 + B4 捕获 + B2 脱敏）
    {
      const view: BrokerManifestView = { allow: [`${base}/*`] };
      const jar = new CookieJar();
      const out = await proxyFetch(`${base}/redirect`, {}, { view, resolver: noResolver, jar, transport });
      assert.equal(out.status, 200, "B3 自跟随到 /echo");
      assert.equal(out.requestCount, 2, "/redirect + /echo 各计一次");
      assert.equal((JSON.parse(out.body!) as Record<string, unknown>).method, "GET");
      assert.equal(out.headers["set-cookie"], undefined, "Set-Cookie 脱敏剥除");
      const harvested = new Set(jar.harvestView().map((c) => `${c.name}=${c.value}`));
      assert.deepEqual(harvested, new Set(["a=1", "b=2"]), "逐跳 Set-Cookie 进 jar origin 区");
      checks++;
    }

    // 5. body 上限：流式读取超限 fail-closed
    {
      const tiny = new DirectTransport(4);
      await assert.rejects(
        tiny.fetch({ url: `${base}/big`, method: "GET", headers: {} }),
        (e: unknown) => e instanceof TransportBodyLimitExceeded,
        "响应 body 超上限应拒绝",
      );
      checks++;
    }

    // 6. A3：UTF-8 JSON 端点 → decodeOk=true（正常明文可交付）
    {
      const resp = await transport.fetch({ url: `${base}/echo`, method: "GET", headers: {} });
      assert.equal(resp.decodeOk, true, "UTF-8 明文应 decodeOk=true");
      checks++;
    }

    // 7. A3：声明非 UTF-8 charset（gbk）→ decodeOk=false（绝不猜测转码）
    {
      const resp = await transport.fetch({ url: `${base}/gbk`, method: "GET", headers: {} });
      assert.equal(resp.decodeOk, false, "非 UTF-8 charset 应 decodeOk=false");
      checks++;
    }

    // 8. A3：声明 UTF-8 但字节非法 → decodeOk=false（fatal 解码失败）
    {
      const resp = await transport.fetch({ url: `${base}/badutf8`, method: "GET", headers: {} });
      assert.equal(resp.decodeOk, false, "非法 UTF-8 字节应 decodeOk=false");
      checks++;
    }
    // 9. P1-04：两个同名 token 头在 WHATWG Headers 里已被折叠，服务端**无法证明**原始基数，
    //    故 `headerCardinalityAttested=false`；经 firewall 的 header 源 Masker 规则必须 fail-closed。
    {
      const resp = await transport.fetch({ url: `${base}/dup-token-header`, method: "GET", headers: {} });
      assert.equal(
        resp.headers["x-session-secret"],
        "TOK_A_FICTITIOUS, TOK_B_FICTITIOUS",
        "WHATWG 折叠为逗号连接",
      );
      assert.equal(resp.headerCardinalityAttested, false, "服务端传输不得声称能证明原始基数");

      const view: BrokerManifestView = {
        allow: [`${base}/*`],
        credentials: {
          "aircon-session": {
            scope: ["https://actuator.invalid/*"],
            type: "header",
            headerName: "x-access-token",
          },
        },
      };
      const store = new CredentialStore(undefined, () => 1_700_000_000_000);
      await assert.rejects(
        proxyFetch(
          `${base}/dup-token-header`,
          {},
          {
            view,
            resolver: noResolver,
            jar: new CookieJar(),
            transport,
            masker: {
              policy: {
                schemaVersion: 1,
                rules: [
                  {
                    id: "dup-token",
                    match: { capability: "notice.list", method: "GET", urlScope: `${base}/*` },
                    capture: {
                      source: "header",
                      name: "x-session-secret",
                      destination: { kind: "credential", ref: "aircon-session" },
                    },
                    project: "delete",
                  },
                ],
              },
              capability: "notice.list",
              sink: store,
              ctx: { schoolId: "test", now: () => 1_700_000_000_000 },
            },
          },
        ),
        (e: unknown) => e instanceof DeliveryFirewallError && e.code === "header_cardinality_unattested",
        "两个同名 token 头须 fail-closed，绝不把折叠值当凭证",
      );
      assert.ok(!(await store.get("aircon-session")), "拒交付时绝不落库");
      checks++;
    }
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  console.log(`transport direct smoke: ${checks}/9 例通过 ✅`);
}

runMain(main);
