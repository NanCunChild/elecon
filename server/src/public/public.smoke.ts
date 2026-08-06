/**
 * 公网端点 D 冒烟 —— 静态分发 + 零凭证/无状态 + 缓存策略 + traversal 守卫（不监听端口，直调 handler）。
 *
 * 在临时 dist/ 上验证:catalog/revocation/bundle 服务、内容寻址 immutable 缓存、404、路径穿越拒绝、
 * 方法守卫、/health。端点**不验签**（客户端职责）——这里只证"按原样发静态文件 + 结构不变量"。
 *
 *   运行：cd server && npm run smoke:public
 */

import { strict as assert } from "node:assert";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

// 先建临时 dist 并注入 PUBLIC_DIST_DIR，再 import handler（handler 运行时读取该 env）。
const dist = mkdtempSync(join(tmpdir(), "elecon-dist-"));
process.env.PUBLIC_DIST_DIR = dist;
mkdirSync(join(dist, "bundles"), { recursive: true });
const CATALOG_GZ = gzipSync(Buffer.from(JSON.stringify({ catalogVersion: "1.0", sequence: 1 })));
const BUNDLE_GZ = gzipSync(Buffer.from(JSON.stringify({ envelope: { bundleFormat: "elecon-bundle/1" } })));
const BUNDLE_DIGEST = "d".repeat(64);
writeFileSync(join(dist, "catalog.json.gz"), CATALOG_GZ);
writeFileSync(join(dist, "revocation.json"), JSON.stringify({ sequence: 1, entries: [] }));
writeFileSync(join(dist, "bundles", `${BUNDLE_DIGEST}.json.gz`), BUNDLE_GZ);
writeFileSync(join(dist, "private.txt"), "must not be public");
writeFileSync(join(dist, "bundles", `${"e".repeat(64)}.json.gz`), Buffer.alloc(512 * 1024 + 1));

const { handler } = await import("./index.js");

interface Captured {
  code: number;
  headers: Record<string, unknown>;
  body?: Buffer;
}

function invoke(url: string, method = "GET"): Captured {
  const cap: Captured = { code: 0, headers: {} };
  const req = { url, method, headers: {} } as IncomingMessage;
  const res = {
    writeHead(code: number, headers?: Record<string, unknown>) {
      cap.code = code;
      cap.headers = headers ?? {};
      return this;
    },
    end(payload?: Buffer | string) {
      if (payload !== undefined) cap.body = Buffer.from(payload as Buffer);
    },
  } as unknown as ServerResponse;
  handler(req, res);
  return cap;
}

try {
  // /health
  {
    const r = invoke("/health");
    assert.equal(r.code, 200);
    assert.deepEqual(JSON.parse(r.body?.toString() ?? "{}"), {
      status: "ok",
      stateless: true,
      zeroCredential: true,
    });
    console.log("✓ /health（无状态/零凭证）");
  }

  // catalog（短缓存 + gzip content-type）
  {
    const r = invoke("/catalog.json.gz");
    assert.equal(r.code, 200);
    assert.equal(r.headers["content-type"], "application/gzip");
    assert.equal(r.headers["cache-control"], "public, max-age=60");
    assert.ok(r.body?.equals(CATALOG_GZ), "catalog 应按原样发出（未改字节）");
    console.log("✓ /catalog.json.gz（短缓存 + 原样字节）");
  }

  // revocation
  {
    const r = invoke("/revocation.json");
    assert.equal(r.code, 200);
    assert.equal(r.headers["content-type"], "application/json");
    console.log("✓ /revocation.json");
  }

  // bundle（内容寻址 → immutable 长缓存）
  {
    const r = invoke(`/bundles/${BUNDLE_DIGEST}.json.gz`);
    assert.equal(r.code, 200);
    assert.equal(r.headers["cache-control"], "public, max-age=31536000, immutable");
    assert.ok(r.body?.equals(BUNDLE_GZ), "bundle 应按原样发出");
    console.log("✓ /bundles/<digest>.json.gz（immutable 长缓存 + 原样字节）");
  }

  // HEAD：有头无体
  {
    const r = invoke("/catalog.json.gz", "HEAD");
    assert.equal(r.code, 200);
    assert.equal(r.body, undefined, "HEAD 不应有 body");
    console.log("✓ HEAD（头无体）");
  }

  // 未知文件 → 404
  {
    assert.equal(invoke("/bundles/nope.json.gz").code, 404);
    assert.equal(invoke("/private.txt").code, 404, "dist 任意文件不得自动公开");
    console.log("✓ 未知文件 → 404");
  }

  // bundle 路径必须是合法 digest，产物大小有硬限制。
  {
    assert.equal(invoke(`/bundles/${"D".repeat(64)}.json.gz`).code, 404, "大写 digest 应拒绝");
    assert.equal(invoke(`/bundles/${"e".repeat(64)}.json.gz`).code, 413, "超限 bundle 应拒绝");
    console.log("✓ bundle digest 路径与产物大小硬限制");
  }

  // 路径穿越 → 拒绝（不泄露 dist 外文件）
  {
    assert.equal(invoke("/../index.js").code, 404, "traversal 应被拒");
    assert.equal(invoke("/..%2f..%2fpackage.json").code, 404, "编码 traversal 应被拒");
    console.log("✓ 路径穿越被拒（fail-closed）");
  }

  // 畸形百分号和非法 UTF-8 必须返回 400，不能让 handler 抛出。
  {
    assert.equal(invoke("/%").code, 400);
    assert.equal(invoke("/%ff").code, 400);
    assert.equal(invoke("/%e0%80%80").code, 400);
    console.log("✓ 畸形 URL 编码返回 400");
  }

  // 非 GET/HEAD → 405
  {
    const r = invoke("/catalog.json.gz", "POST");
    assert.equal(r.code, 405);
    console.log("✓ 非 GET/HEAD → 405");
  }

  console.log("\npublic 端点 D smoke 全部通过 ✅  —— 端点只发静态签名产物,验签是客户端职责。");
} finally {
  rmSync(dist, { recursive: true, force: true });
}
