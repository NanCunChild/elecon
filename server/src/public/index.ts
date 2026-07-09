/**
 * 公网哑服务（public）—— 无状态、零凭证。
 *
 * 红线（AGENTS.md #1/#2）：本服务**永远不得持有或持久化任何凭证 / 私密数据**。
 * 它只做两件事：① 分发**已签名** adapter 包；② 缓存**公开**（非私密）数据。
 *
 * 🔒 承重路径（红线 #4：仅官方签名可加载）。本文件是**骨架**：路由/分发/零凭证结构
 *    已实现供审阅；**验签 gate 的 pin 公钥接线**与真实 bundle 存储/CDN 由维护者人工闭环
 *    （复用 tools/src/signer 的 verifyAdapter；AGENTS.md §1）。
 *
 * 无状态不变量（结构强制）：
 *  - 本进程**只读** adapter 目录 + **进程内**公开数据缓存（可丢弃）；不写任何持久化存储。
 *  - 请求里若带任何疑似凭证头（Cookie/Authorization），一律**忽略且不记录**（不因哑服务落库）。
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.PORT ?? 8080);
const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const ADAPTERS_DIR = process.env.ADAPTERS_DIR ?? join(repoRoot, "adapters");

// ---- 零凭证守卫：忽略并拒绝携带凭证的请求被"处理成有态" ----

/** 哑服务永不消费凭证；带凭证头的请求照常服务公开资源，但绝不读取/记录该头。 */
function assertZeroCredentialSafe(req: IncomingMessage): void {
  // 结构性提醒：不读取 req.headers.cookie / authorization 做任何分支。
  // 若未来有人在 public 里引用这两个头，code review 应据本约束拒绝（红线 #2）。
  void req;
}

// ---- adapter 分发 ----

function json(res: ServerResponse, code: number, body: unknown): void {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

/** 列出可分发的 adapter（含 manifest 摘要）。仅公开元数据，零凭证。 */
function listAdapters(): Array<{ adapterId: string; adapterVersion: string; signed: boolean }> {
  const out: Array<{ adapterId: string; adapterVersion: string; signed: boolean }> = [];
  if (!existsSync(ADAPTERS_DIR)) return out;
  for (const entry of readdirSync(ADAPTERS_DIR)) {
    const dir = join(ADAPTERS_DIR, entry);
    const manifestPath = join(dir, "manifest.json");
    if (!statSync(dir).isDirectory() || !existsSync(manifestPath)) continue;
    try {
      const m = JSON.parse(readFileSync(manifestPath, "utf-8")) as {
        adapterId: string;
        adapterVersion: string;
      };
      out.push({
        adapterId: m.adapterId,
        adapterVersion: m.adapterVersion,
        signed: existsSync(join(dir, "signature.json")),
      });
    } catch {
      // 损坏 manifest：不分发（fail-closed），不影响其它。
    }
  }
  return out;
}

/**
 * 🔒 待人工闭环：分发前验签 gate。
 * 复用 tools/src/signer 的 verifyAdapter(dir, pinnedPublicKey)——只分发验签通过的 official bundle。
 * pin 公钥加载（active key）与验签接线是承重路径，须人工审。骨架先返回"未接线"。
 */
function serveAdapterBundle(res: ServerResponse, adapterId: string): void {
  const list = listAdapters();
  const found = list.find((a) => a.adapterId === adapterId);
  if (!found) return json(res, 404, { status: "not_found", adapterId });
  if (!found.signed) {
    // release 只分发已签名 bundle（红线 #4）——未签名一律拒绝。
    return json(res, 403, { status: "unsigned_rejected", detail: "release 仅分发官方签名 adapter" });
  }
  // 🔒 验签 gate 未接线：pin 公钥 + verifyAdapter 由维护者人工闭环。
  return json(res, 501, {
    status: "not_implemented",
    detail: "adapter bundle 分发的验签 gate（pin 公钥 + signer.verifyAdapter）待人工闭环",
  });
}

function handler(req: IncomingMessage, res: ServerResponse): void {
  assertZeroCredentialSafe(req);
  const url = req.url ?? "/";

  if (url === "/health") {
    return json(res, 200, { status: "ok", stateless: true, zeroCredential: true });
  }

  if (url === "/adapters" || url === "/adapters/") {
    return json(res, 200, { adapters: listAdapters() });
  }

  const m = url.match(/^\/adapters\/([^/]+)\/?$/);
  if (m) {
    return serveAdapterBundle(res, decodeURIComponent(m[1] ?? ""));
  }

  if (url === "/revocations") {
    // 🔒 待人工闭环：分发已签名吊销清单（tools/src/signer/revocation.ts），公开、零凭证（ADR-002 §2.4）。
    return json(res, 501, { status: "not_implemented", detail: "signed revocation list 分发待人工闭环" });
  }

  return json(res, 404, { status: "not_found" });
}

// 仅在被直接执行时监听端口；被 import（测试）时导出 handler。
export { handler, listAdapters };

const invokedDirectly =
  process.argv[1] !== undefined && process.argv[1] === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const server = createServer(handler);
  server.listen(PORT, () => {
    console.log(`elecon public server (dumb, stateless, zero-credential) listening on :${PORT}`);
  });
}
