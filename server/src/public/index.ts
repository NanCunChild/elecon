/**
 * 公网端点 D —— adapter 分发的**无状态、零凭证静态服务**（ADR-018 §2.1 D / §2.9；红线 #2）。
 *
 * 只做一件事：把**预先构建、已签名**的静态产物按原样发出去。
 * **不签名、不验签、不读 adapter 源、不持任何状态或凭证。** 完整性由**客户端**对 pin 公钥验签
 * 保证（ADR-002 §2.3/§2.6）——端点被投毒也无法提权:篡改的 bundle/catalog 在客户端验签 fail-closed。
 * 故本服务可无差别替换为任意静态托管 / CDN / 对象存储（红线 #2「可退化为静态托管」）。本 Node
 * 实现只是参考;生产建议前置 CDN。
 *
 * 服务的静态根 = `PUBLIC_DIST_DIR`（缺省 `dist/`，布局见 deploy/public-endpoint/README.md）：
 *   /catalog.json.gz          签名 catalog（gzip-JSON）           —— 短缓存（新鲜度靠 sequence/TTL）
 *   /revocation.json          签名吊销清单（ADR-002 §2.4）        —— 短缓存
 *   /bundles/<digest>.json.gz 内容寻址签名 bundle（§2.9）         —— immutable 长缓存
 *
 * 无状态不变量（结构强制）：只读 dist/ 静态文件;不写任何持久化;忽略且不记录 Cookie/Authorization。
 */

import { existsSync, readFileSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.PORT ?? 8080);
const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

/** 静态根;运行时读取（便于测试注入 PUBLIC_DIST_DIR）。 */
function distDir(): string {
  return resolve(process.env.PUBLIC_DIST_DIR ?? join(repoRoot, "dist"));
}

const CACHE_IMMUTABLE = "public, max-age=31536000, immutable"; // 内容寻址 bundle
const CACHE_SHORT = "public, max-age=60"; // catalog / revocation

function cacheFor(urlPath: string): string {
  return urlPath.startsWith("/bundles/") ? CACHE_IMMUTABLE : CACHE_SHORT;
}

function contentType(urlPath: string): string {
  if (urlPath.endsWith(".json.gz")) return "application/gzip";
  if (urlPath.endsWith(".json")) return "application/json";
  return "application/octet-stream";
}

/** 把 URL 路径解析到 dist 内的绝对路径;越界（traversal）返回 null。 */
function resolveSafe(urlPath: string): string | null {
  const dir = distDir();
  const rel = decodeURIComponent(urlPath).replace(/^\/+/, "");
  const abs = resolve(dir, rel);
  if (abs !== dir && !abs.startsWith(dir + sep)) return null; // fail-closed 出界即拒
  return abs;
}

function notFound(res: ServerResponse): void {
  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ status: "not_found" }));
}

export function handler(req: IncomingMessage, res: ServerResponse): void {
  // 零凭证：绝不读取 req.headers.cookie / authorization 做任何分支或记录（红线 #2）。
  const method = req.method ?? "GET";
  const urlPath = (req.url ?? "/").split("?")[0] ?? "/";

  if (urlPath === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok", stateless: true, zeroCredential: true }));
    return;
  }

  if (method !== "GET" && method !== "HEAD") {
    res.writeHead(405, { "content-type": "application/json", allow: "GET, HEAD" });
    res.end(JSON.stringify({ status: "method_not_allowed" }));
    return;
  }

  const abs = resolveSafe(urlPath);
  if (abs === null || !existsSync(abs) || !statSync(abs).isFile()) {
    notFound(res);
    return;
  }

  const body = readFileSync(abs); // 静态小文件（bundle ≤ C11 上限）;生产前置 CDN。
  res.writeHead(200, {
    "content-type": contentType(urlPath),
    "content-length": body.length,
    "cache-control": cacheFor(urlPath),
    "x-content-type-options": "nosniff",
  });
  res.end(method === "HEAD" ? undefined : body);
}

const invokedDirectly = process.argv[1] !== undefined && process.argv[1] === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const server = createServer(handler);
  server.listen(PORT, () => {
    console.log(
      `elecon public endpoint D (static, stateless, zero-credential) on :${PORT}  dist=${distDir()}`,
    );
  });
}
